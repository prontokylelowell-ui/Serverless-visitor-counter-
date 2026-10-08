$ErrorActionPreference = "Continue"

$REGION = if ($args.Count -ge 1) { $args[0] } else { "us-east-1" }
$TABLE_NAME = if ($args.Count -ge 2) { $args[1] } else { "visitor-counter" }
$ROLE_NAME = "VisitorCounterLambdaRole"
$POLICY_NAME = "VisitorCounterLambdaPolicy"
$FUNCTION_NAME = "VisitorCounter"
$API_NAME = "VisitorCounterAPI"
$STAGE_NAME = "dev"

$PROJECT_DIR = Split-Path -Parent $PSScriptRoot
$LAMBDA_DIR = Join-Path $PROJECT_DIR "lambda"
$IAM_DIR = Join-Path $PROJECT_DIR "iam"
$BUILD_DIR = Join-Path $PROJECT_DIR "build"
$PACKAGE_DIR = Join-Path $BUILD_DIR "package"
$ZIP_FILE = Join-Path $BUILD_DIR "lambda-package.zip"

Write-Host "======================================"
Write-Host "Starting deployment to region: $REGION"
Write-Host "======================================"

if (-not (Test-Path $BUILD_DIR)) {
    New-Item -ItemType Directory -Path $BUILD_DIR -Force | Out-Null
}

Write-Host ""
Write-Host "Step 1: Creating DynamoDB table..."
& "$PROJECT_DIR\scripts\create-dynamodb-table.ps1" $TABLE_NAME $REGION

Write-Host ""
Write-Host "Step 2: Creating IAM Role..."

$roleCheck = aws iam get-role --role-name $ROLE_NAME --region $REGION 2>$null
if (-not $roleCheck) {
    Write-Host "Creating new role: $ROLE_NAME"
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://$IAM_DIR\lambda-role-trust-policy.json --region $REGION | Out-Null
} else {
    Write-Host "Role $ROLE_NAME already exists"
}

Write-Host "Creating/Getting policy: $POLICY_NAME"
$policyArn = aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text --region $REGION
if (-not $policyArn -or $policyArn -eq "None") {
    $policyArn = aws iam create-policy --policy-name $POLICY_NAME --policy-document file://$IAM_DIR\lambda-policy.json --query 'Policy.Arn' --output text --region $REGION
}
Write-Host "Policy ARN: $policyArn"

aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $policyArn --region $REGION 2>$null
Write-Host "Policy attached to role"

$ROLE_ARN = aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text --region $REGION
Write-Host "Role ARN: $ROLE_ARN"
Write-Host "Waiting 10s for role propagation..."
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "Step 3: Building Lambda package..."

if (Test-Path $PACKAGE_DIR) {
    Remove-Item -Path $PACKAGE_DIR -Recurse -Force
}
New-Item -ItemType Directory -Path $PACKAGE_DIR -Force | Out-Null

Push-Location $LAMBDA_DIR
pip install -r requirements.txt -t $PACKAGE_DIR
Copy-Item visitor_counter.py -Destination (Join-Path $PACKAGE_DIR "visitor_counter.py")
Pop-Location

if (Test-Path $ZIP_FILE) {
    Remove-Item $ZIP_FILE -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($PACKAGE_DIR, $ZIP_FILE)
Write-Host "Package created at $ZIP_FILE"

Write-Host ""
Write-Host "Step 4: Creating/Updating Lambda function..."

$functionExists = $false
$func = aws lambda get-function --function-name $FUNCTION_NAME --region $REGION 2>$null
if ($func) { $functionExists = $true }

if ($functionExists) {
    Write-Host "Updating existing function..."
    aws lambda update-function-code --function-name $FUNCTION_NAME --zip-file fileb://$ZIP_FILE --region $REGION | Out-Null
    aws lambda update-function-configuration --function-name $FUNCTION_NAME --role $ROLE_ARN --handler visitor_counter.lambda_handler --runtime python3.9 --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME,COUNTER_ID=main}" --region $REGION | Out-Null
} else {
    Write-Host "Creating new function..."
    aws lambda create-function --function-name $FUNCTION_NAME --runtime python3.9 --role $ROLE_ARN --handler visitor_counter.lambda_handler --zip-file fileb://$ZIP_FILE --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME,COUNTER_ID=main}" --timeout 10 --memory-size 128 --region $REGION | Out-Null
}

$LAMBDA_ARN = aws lambda get-function --function-name $FUNCTION_NAME --query 'Configuration.FunctionArn' --output text --region $REGION
Write-Host "Lambda ARN: $LAMBDA_ARN"

Write-Host ""
Write-Host "Step 5: Setting up API Gateway..."

$API_ID = aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region $REGION

if (-not $API_ID -or $API_ID -eq "None") {
    Write-Host "Creating new REST API..."
    $API_ID = aws apigateway create-rest-api --name $API_NAME --description "Serverless Visitor Counter API" --query 'id' --output text --region $REGION
    Write-Host "New API ID: $API_ID"

    $ROOT_RESOURCE_ID = aws apigateway get-resources --rest-api-id $API_ID --query 'items[0].id' --output text --region $REGION

    Write-Host "Creating /visits resource..."
    $VISITS_RESOURCE_ID = aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_RESOURCE_ID --path-part "visits" --query 'id' --output text --region $REGION

    Write-Host "Creating /visits/reset resource..."
    $RESET_RESOURCE_ID = aws apigateway create-resource --rest-api-id $API_ID --parent-id $VISITS_RESOURCE_ID --path-part "reset" --query 'id' --output text --region $REGION

    $ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
    $LAMBDA_URI = "arn:aws:apigateway:" + $REGION + ":lambda:path/2015-03-31/functions/" + $LAMBDA_ARN + "/invocations"

    foreach ($METHOD in @("GET", "POST", "OPTIONS")) {
        Write-Host "Setting up $METHOD /visits..."
        aws apigateway put-method --rest-api-id $API_ID --resource-id $VISITS_RESOURCE_ID --http-method $METHOD --authorization-type "NONE" --no-api-key-required --region $REGION 2>$null | Out-Null
        aws apigateway put-integration --rest-api-id $API_ID --resource-id $VISITS_RESOURCE_ID --http-method $METHOD --type AWS_PROXY --integration-http-method POST --uri $LAMBDA_URI --region $REGION 2>$null | Out-Null
    }

    foreach ($METHOD in @("POST", "OPTIONS")) {
        Write-Host "Setting up $METHOD /visits/reset..."
        aws apigateway put-method --rest-api-id $API_ID --resource-id $RESET_RESOURCE_ID --http-method $METHOD --authorization-type "NONE" --no-api-key-required --region $REGION 2>$null | Out-Null
        aws apigateway put-integration --rest-api-id $API_ID --resource-id $RESET_RESOURCE_ID --http-method $METHOD --type AWS_PROXY --integration-http-method POST --uri $LAMBDA_URI --region $REGION 2>$null | Out-Null
    }

    Write-Host "Adding Lambda permission for API Gateway..."
    $SOURCE_ARN = "arn:aws:execute-api:" + $REGION + ":" + $ACCOUNT_ID + ":" + $API_ID + "/*/*/*"
    aws lambda add-permission --function-name $FUNCTION_NAME --statement-id "apigateway-invoke-$FUNCTION_NAME" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn $SOURCE_ARN --region $REGION 2>$null | Out-Null
} else {
    Write-Host "Using existing API ID: $API_ID"
}

Write-Host ""
Write-Host "Step 6: Deploying API to stage: $STAGE_NAME..."
aws apigateway create-deployment --rest-api-id $API_ID --stage-name $STAGE_NAME --stage-description "Development stage" --description "Auto deployment" --region $REGION 2>$null | Out-Null

$API_URL = "https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE_NAME"

Write-Host ""
Write-Host "======================================"
Write-Host "Deployment complete!"
Write-Host "======================================"
Write-Host ""
Write-Host "API Endpoint: $API_URL"
Write-Host ""
Write-Host "Test endpoints:"
Write-Host "  GET    $API_URL/visits          -> Get current visits"
Write-Host "  POST   $API_URL/visits          -> Increment visits (returns new count)"
Write-Host "  POST   $API_URL/visits/reset    -> Reset counter to 0"
Write-Host ""
Write-Host "Example (curl):"
Write-Host "  curl -X POST $API_URL/visits"
Write-Host ""
