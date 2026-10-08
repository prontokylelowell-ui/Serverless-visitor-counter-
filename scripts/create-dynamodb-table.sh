TABLE_NAME="${1:-visitor-counter}"
REGION="${2:-us-east-1}"

echo "Creating DynamoDB table: $TABLE_NAME in region: $REGION..."

aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION"

echo "Waiting for table to be active..."
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
echo "Table $TABLE_NAME is ready."
