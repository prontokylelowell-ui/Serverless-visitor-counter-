# Serverless Visitor Counter API

A production-ready, fully serverless visitor counter built with **AWS Lambda**, **API Gateway**, and **DynamoDB**. Each API call atomically increments a counter stored in DynamoDB and returns the current count as JSON (e.g. `{"visits": 42}`). A simple frontend is included to display the number in a browser.

## Project Structure

```
Serverless visitor counter or to-do API/
├── lambda/
│   ├── visitor_counter.py       # Lambda handler (Python 3.9)
│   └── requirements.txt         # boto3 dependency
├── iam/
│   ├── lambda-role-trust-policy.json   # Lambda role trust policy
│   └── lambda-policy.json              # DynamoDB + CloudWatch IAM policy
├── scripts/
│   ├── deploy.sh                     # Full one-click deploy (Bash / macOS / Linux)
│   ├── deploy.ps1                    # Full one-click deploy (PowerShell / Windows)
│   ├── create-dynamodb-table.sh      # DynamoDB table only (Bash)
│   └── create-dynamodb-table.ps1     # DynamoDB table only (PowerShell)
├── frontend/
│   └── index.html             # Pretty counter UI (open in any browser)
└── tests/
    └── VisitorCounter.postman_collection.json   # Import into Postman
```

## Architecture

```
Browser / Postman  ──▶  API Gateway (REST)  ──▶  Lambda (Python)  ──▶  DynamoDB
                          (CORS enabled)          (atomic update)        (single item)
```

- **DynamoDB table**: `visitor-counter` — one row with `id=main`, `visits=<number>`, on-demand billing.
- **Lambda function**: `VisitorCounter` — 128 MB, Python 3.9, uses `UpdateItem` with `if_not_exists` for thread-safe increments.
- **API Gateway REST API**: `VisitorCounterAPI` with stage `dev` — AWS_PROXY integration, GET/POST/OPTIONS on `/visits` and `/visits/reset`.

## Prerequisites

1. **AWS Account** with programmatic access keys.
2. **AWS CLI v2** installed and configured:
   ```bash
   aws configure
   ```
3. **Python 3.9+** and **pip** (to package the Lambda layer).
4. *(Optional)* **Postman** to import the test collection.
5. *(Optional)* **zip** utility on Linux/macOS (PowerShell on Windows uses .NET compression).

## Quick Deploy (One Command)

### Windows (PowerShell)
```powershell
cd "Serverless visitor counter or to-do API"
.\scripts\deploy.ps1                        # defaults to us-east-1
# or:
.\scripts\deploy.ps1 us-west-2              # specify region
.\scripts\deploy.ps1 eu-west-1 my-counter   # specify region + table name
```

### macOS / Linux (Bash)
```bash
cd "Serverless visitor counter or to-do API"
chmod +x scripts/*.sh
./scripts/deploy.sh                         # defaults to us-east-1
# or:
./scripts/deploy.sh us-west-2               # specify region
./scripts/deploy.sh eu-west-1 my-counter    # specify region + table name
```

The script prints your API URL when done, for example:
```
API Endpoint: https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev
```

## API Endpoints

Replace `{API_URL}` with the URL printed by the deploy script.

| Method | Path                | Description                                      | Example Response              |
|--------|---------------------|--------------------------------------------------|-------------------------------|
| `GET`  | `/visits`           | Read the current count (does not increment)      | `{"visits": 42}`              |
| `POST` | `/visits`           | **Increment** counter and return new value       | `{"visits": 43}`              |
| `POST` | `/visits/reset`     | Reset counter to 0                                | `{"visits": 0, "message": "Counter reset successfully"}` |
| `OPTIONS` | `/visits` or `/visits/reset` | CORS preflight (returns 200 + CORS headers) | *empty body* |

### Testing with curl
```bash
# Increment counter (what you'd link to a "page view")
curl -X POST https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev/visits
# => {"visits": 1}

curl -X POST https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev/visits
# => {"visits": 2}

# Read without incrementing
curl https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev/visits
# => {"visits": 2}

# Reset
curl -X POST https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev/visits/reset
# => {"visits":0,"message":"Counter reset successfully"}
```

### Testing with Postman
1. Open Postman → **Import** → select `tests/VisitorCounter.postman_collection.json`.
2. In the collection, open the **Variables** tab, set `baseUrl` to your deployed API URL (e.g. `https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev`), and **Save**.
3. Run the requests in order: **Get Current Visits** → **Increment Visits** → **Reset Counter**.

## Use the Frontend

1. Open `frontend/index.html` in any web browser (double-click it, or serve with `python -m http.server`).
2. Paste your API base URL (e.g. `https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev`) into the textbox at the bottom. The URL is saved in `localStorage` so you don't have to re-paste it.
3. Click **+ Increment Count** — the counter animates up and the JSON response is shown as a status message.

To wire it permanently to your site, edit `index.html` and change:
```html
<input id="apiUrl" ... placeholder="..." value="https://YOUR_API_URL_HERE">
```
Or simply call the API from your own site with the `fetch` pattern shown in the file.

## How the Lambda Code Works

Core logic in [lambda/visitor_counter.py](lambda/visitor_counter.py):

- **`GET /visits`** → `get_visits()`: does a `GetItem` on `id=main`; returns `0` if the row doesn't exist yet.
- **`POST /visits`** → `increment_visits()`: uses **DynamoDB atomic update**:
  ```python
  table.update_item(
      Key={'id': COUNTER_ID},
      UpdateExpression='SET visits = if_not_exists(visits, :start) + :inc',
      ExpressionAttributeValues={':start': 0, ':inc': 1},
      ReturnValues='UPDATED_NEW',
  )
  ```
  This is safe under concurrent requests because DynamoDB executes `UpdateItem` serially per key — you'll never double-count or miss a visit.
- **CORS** is handled explicitly (even for `OPTIONS` preflight) so browser-based frontends work with no proxy.
- **Environment variables** `DYNAMODB_TABLE` and `COUNTER_ID` let you reuse the function for multiple counters by creating new Lambda aliases/configurations.

## Cleanup (Remove Everything)

To avoid future AWS charges, delete the resources when you're done:

```bash
# 1. API Gateway
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='VisitorCounterAPI'].id" --output text)
aws apigateway delete-rest-api --rest-api-id "$API_ID"

# 2. Lambda function
aws lambda delete-function --function-name VisitorCounter

# 3. IAM (detach policy first, then role, then policy)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/VisitorCounterLambdaPolicy"
aws iam detach-role-policy  --role-name VisitorCounterLambdaRole --policy-arn "$POLICY_ARN"
aws iam delete-role         --role-name VisitorCounterLambdaRole
aws iam delete-policy       --policy-arn "$POLICY_ARN"

# 4. DynamoDB table
aws dynamodb delete-table --table-name visitor-counter

# 5. CloudWatch log group (optional, logs auto-expire but you can delete manually)
aws logs delete-log-group --log-group-name /aws/lambda/VisitorCounter
```

## Extending It

- **Multiple counters**: add a `?counter=portfolio-xyz` query string in API Gateway, read it from `event['queryStringParameters']`, and use it as the `id` in DynamoDB.
- **Rate limiting**: in API Gateway → Stages → `dev` → Settings, set a throttle (e.g. 100 req/s, burst 50).
- **Authentication**: add an API Key (Usage Plan) or switch the `GET/POST` methods to `AWS_IAM` / Cognito Authorizer.
- **Custom domain**: Route 53 + ACM + API Gateway Custom Domain Name.
- **Switch to To-Do API**: change the DynamoDB schema to `(PK=userId, SK=todoId, title, done)` and swap `visitor_counter.py` for CRUD methods (`List`, `Create`, `Update`, `Delete`) with API Gateway routes `/todos`, `/todos/{id}`.

## Files Reference

- Lambda handler: [lambda/visitor_counter.py](lambda/visitor_counter.py)
- Lambda deps: [lambda/requirements.txt](lambda/requirements.txt)
- IAM trust policy: [iam/lambda-role-trust-policy.json](iam/lambda-role-trust-policy.json)
- IAM permissions policy: [iam/lambda-policy.json](iam/lambda-policy.json)
- Deploy scripts: [scripts/deploy.sh](scripts/deploy.sh), [scripts/deploy.ps1](scripts/deploy.ps1)
- Frontend: [frontend/index.html](frontend/index.html)
- Postman collection: [tests/VisitorCounter.postman_collection.json](tests/VisitorCounter.postman_collection.json)
