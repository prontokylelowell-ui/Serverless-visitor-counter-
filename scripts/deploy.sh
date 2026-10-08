REGION="${1:-us-east-1}"
TABLE_NAME="${2:-visitor-counter}"
ROLE_NAME="VisitorCounterLambdaRole"
POLICY_NAME="VisitorCounterLambdaPolicy"
FUNCTION_NAME="VisitorCounter"
API_NAME="VisitorCounterAPI"
STAGE_NAME="dev"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAMBDA_DIR="$PROJECT_DIR/lambda"
IAM_DIR="$PROJECT_DIR/iam"
BUILD_DIR="$PROJECT_DIR/build"
ZIP_FILE="$BUILD_DIR/lambda-package.zip"

echo "======================================"
echo "Starting deployment to region: $REGION"
echo "======================================"

mkdir -p "$BUILD_DIR"

echo "Step 1: Creating DynamoDB table..."
bash "$PROJECT_DIR/scripts/create-dynamodb-table.sh" "$TABLE_NAME" "$REGION"

echo ""
echo "Step 2: Creating IAM Role..."

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://"$IAM_DIR/lambda-role-trust-policy.json" \
  --region "$REGION" 2>/dev/null || echo "Role $ROLE_NAME already exists or skipped"

echo "Attaching policy to role..."
POLICY_ARN=$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://"$IAM_DIR/lambda-policy.json" \
  --query 'Policy.Arn' \
  --output text \
  --region "$REGION" 2>/dev/null || \
  aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text --region "$REGION")

echo "Policy ARN: $POLICY_ARN"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" \
  --region "$REGION" 2>/dev/null || echo "Policy already attached or skipped"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text --region "$REGION")
echo "Role ARN: $ROLE_ARN"
echo "Waiting 10s for role propagation..."
sleep 10

echo ""
echo "Step 3: Building Lambda package..."
cd "$LAMBDA_DIR"
pip install -r requirements.txt -t "$BUILD_DIR/package" --platform manylinux2014_x86_64 --python-version 3.9 --only-binary=:all: 2>/dev/null || pip install -r requirements.txt -t "$BUILD_DIR/package"
cp visitor_counter.py "$BUILD_DIR/package/"
cd "$BUILD_DIR/package"
zip -r "$ZIP_FILE" .
echo "Package created at $ZIP_FILE"

echo ""
echo "Step 4: Creating/Updating Lambda function..."

FUNCTION_EXISTS=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null && echo "yes" || echo "no")

if [ "$FUNCTION_EXISTS" = "yes" ]; then
  echo "Updating existing function..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://"$ZIP_FILE" \
    --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --role "$ROLE_ARN" \
    --handler visitor_counter.lambda_handler \
    --runtime python3.9 \
    --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME,COUNTER_ID=main}" \
    --region "$REGION"
else
  echo "Creating new function..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.9 \
    --role "$ROLE_ARN" \
    --handler visitor_counter.lambda_handler \
    --zip-file fileb://"$ZIP_FILE" \
    --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME,COUNTER_ID=main}" \
    --timeout 10 \
    --memory-size 128 \
    --region "$REGION"
fi

LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text --region "$REGION")
echo "Lambda ARN: $LAMBDA_ARN"

echo ""
echo "Step 5: Setting up API Gateway..."

API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region "$REGION")

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  echo "Creating new REST API..."
  API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "Serverless Visitor Counter API" \
    --query 'id' \
    --output text \
    --region "$REGION")
  echo "New API ID: $API_ID"

  ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text --region "$REGION")

  echo "Creating /visits resource..."
  VISITS_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_RESOURCE_ID" \
    --path-part "visits" \
    --query 'id' \
    --output text \
    --region "$REGION")

  echo "Creating /visits/reset resource..."
  RESET_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$VISITS_RESOURCE_ID" \
    --path-part "reset" \
    --query 'id' \
    --output text \
    --region "$REGION")

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  LAMBDA_URI="arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations"

  for METHOD in GET POST OPTIONS; do
    echo "Setting up $METHOD /visits..."
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$VISITS_RESOURCE_ID" \
      --http-method "$METHOD" \
      --authorization-type "NONE" \
      --no-api-key-required \
      --region "$REGION" > /dev/null 2>&1

    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$VISITS_RESOURCE_ID" \
      --http-method "$METHOD" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "$LAMBDA_URI" \
      --region "$REGION" > /dev/null 2>&1
  done

  for METHOD in POST OPTIONS; do
    echo "Setting up $METHOD /visits/reset..."
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$RESET_RESOURCE_ID" \
      --http-method "$METHOD" \
      --authorization-type "NONE" \
      --no-api-key-required \
      --region "$REGION" > /dev/null 2>&1

    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$RESET_RESOURCE_ID" \
      --http-method "$METHOD" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "$LAMBDA_URI" \
      --region "$REGION" > /dev/null 2>&1
  done

  echo "Adding Lambda permission for API Gateway..."
  SOURCE_ARN="arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/*"
  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway-invoke-$FUNCTION_NAME" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "$SOURCE_ARN" \
    --region "$REGION" 2>/dev/null || echo "Permission already exists"
else
  echo "Using existing API ID: $API_ID"
fi

echo ""
echo "Step 6: Deploying API to stage: $STAGE_NAME..."
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --stage-description "Development stage" \
  --description "Auto deployment" \
  --region "$REGION" > /dev/null

API_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE_NAME"

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "API Endpoint: $API_URL"
echo ""
echo "Test endpoints:"
echo "  GET    $API_URL/visits          -> Get current visits"
echo "  POST   $API_URL/visits          -> Increment visits (returns new count)"
echo "  POST   $API_URL/visits/reset    -> Reset counter to 0"
echo ""
echo "Example (curl):"
echo "  curl -X POST $API_URL/visits"
echo ""
