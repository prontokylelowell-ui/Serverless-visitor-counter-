$TABLE_NAME = if ($args.Count -ge 1) { $args[0] } else { "visitor-counter" }
$REGION = if ($args.Count -ge 2) { $args[1] } else { "us-east-1" }

Write-Host "Creating DynamoDB table: $TABLE_NAME in region: $REGION..."

aws dynamodb create-table `
  --table-name "$TABLE_NAME" `
  --attribute-definitions AttributeName=id,AttributeType=S `
  --key-schema AttributeName=id,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST `
  --region "$REGION"

Write-Host "Waiting for table to be active..."
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
Write-Host "Table $TABLE_NAME is ready."
