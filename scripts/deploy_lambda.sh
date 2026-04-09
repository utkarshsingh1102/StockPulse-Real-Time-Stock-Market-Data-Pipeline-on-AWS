#!/usr/bin/env bash
# =============================================================================
# StockPulse — Lambda Deployment Script
# Packages and deploys both Lambda functions (ingester + processor).
#
# Usage:
#   ./scripts/deploy_lambda.sh
#
# Prerequisites:
#   - AWS CLI configured
#   - IAM roles created (run infrastructure/setup/create_resources.sh first)
#   - Docker available (for building PyArrow Lambda Layer)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env (gitignored) — keeps secrets out of this script and version control.
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLYGON_SECRET_NAME="${POLYGON_SECRET_NAME:-stockpulse/polygon-api-key}"
SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-stockpulse-queue}"
S3_BUCKET="${S3_BUCKET:-stockpulse-data-us}"
SYMBOLS="${SYMBOLS:-AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ}"

INGESTER_ROLE="arn:aws:iam::$ACCOUNT_ID:role/stockpulse-ingester-role"
PROCESSOR_ROLE="arn:aws:iam::$ACCOUNT_ID:role/stockpulse-processor-role"
BUILD_DIR="$PROJECT_ROOT/.build"

mkdir -p "$BUILD_DIR"

# Resolve SQS queue URL
SQS_QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "$SQS_QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query QueueUrl \
  --output text)

SQS_QUEUE_ARN="arn:aws:sqs:$AWS_REGION:$ACCOUNT_ID:$SQS_QUEUE_NAME"

echo "============================================================"
echo "StockPulse — Lambda Deployment"
echo "Region:  $AWS_REGION | Account: $ACCOUNT_ID"
echo "SQS Queue: $SQS_QUEUE_URL"
echo "============================================================"

# ---------------------------------------------------------------------------
# Step 1: Build PyArrow Lambda Layer (required for processor)
# ---------------------------------------------------------------------------
echo ""
echo "[1/4] Building PyArrow Lambda Layer (requires Docker)..."

LAYER_DIR="$BUILD_DIR/pyarrow-layer"
LAYER_ZIP="$BUILD_DIR/pyarrow-layer.zip"

if [ -f "$LAYER_ZIP" ]; then
  echo "  Layer zip already exists at $LAYER_ZIP — skipping Docker build"
  echo "  Delete $LAYER_ZIP to force rebuild."
else
  rm -rf "$LAYER_DIR"
  mkdir -p "$LAYER_DIR"

  docker run --rm \
    --platform linux/amd64 \
    --entrypoint bash \
    -v "$LAYER_DIR:/output" \
    public.ecr.aws/lambda/python:3.11 \
    -c "pip install --upgrade pip && \
        pip install --only-binary=:all: 'pyarrow==14.0.2' 'numpy<2' -t /output/python/ && \
        echo 'PyArrow installed successfully'"

  (cd "$LAYER_DIR" && zip -r "$LAYER_ZIP" python/)
  echo "  Layer zip created: $LAYER_ZIP"
fi

# Layer zip exceeds Lambda's 69MB direct upload limit — upload via S3
S3_SCRIPTS_BUCKET="${S3_SCRIPTS_BUCKET:-stockpulse-scripts-us}"
LAYER_S3_KEY="layers/pyarrow-layer.zip"

echo "  Uploading layer zip to s3://$S3_SCRIPTS_BUCKET/$LAYER_S3_KEY ..."
aws s3 cp "$LAYER_ZIP" "s3://$S3_SCRIPTS_BUCKET/$LAYER_S3_KEY" --region "$AWS_REGION"

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name "stockpulse-pyarrow" \
  --description "PyArrow for StockPulse processor (Amazon Linux 2, Python 3.11)" \
  --content "S3Bucket=$S3_SCRIPTS_BUCKET,S3Key=$LAYER_S3_KEY" \
  --compatible-runtimes python3.11 \
  --compatible-architectures x86_64 \
  --region "$AWS_REGION" \
  --query LayerVersionArn \
  --output text)

echo "  PyArrow layer published: $LAYER_ARN"

# ---------------------------------------------------------------------------
# Step 2: Deploy Lambda Ingester
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] Packaging Lambda Ingester..."

INGESTER_DIR="$PROJECT_ROOT/lambda/ingester"
INGESTER_ZIP="$BUILD_DIR/ingester.zip"

(cd "$INGESTER_DIR" && zip -r "$INGESTER_ZIP" lambda_function.py)
echo "  Packaged: $INGESTER_ZIP"

if aws lambda get-function \
    --function-name "stockpulse-ingester" \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  echo "  Updating existing ingester Lambda..."
  aws lambda update-function-code \
    --function-name "stockpulse-ingester" \
    --zip-file "fileb://$INGESTER_ZIP" \
    --region "$AWS_REGION"

  aws lambda wait function-updated \
    --function-name "stockpulse-ingester" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "stockpulse-ingester" \
    --timeout 180 \
    --environment "{\"Variables\":{\"POLYGON_SECRET_NAME\":\"$POLYGON_SECRET_NAME\",\"SQS_QUEUE_URL\":\"$SQS_QUEUE_URL\",\"SYMBOLS\":\"$SYMBOLS\"}}" \
    --region "$AWS_REGION"

  aws lambda tag-resource \
    --resource "arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:stockpulse-ingester" \
    --tags "project-name=StockPulse" \
    --region "$AWS_REGION"
else
  echo "  Creating ingester Lambda..."
  aws lambda create-function \
    --function-name "stockpulse-ingester" \
    --runtime python3.11 \
    --role "$INGESTER_ROLE" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$INGESTER_ZIP" \
    --timeout 180 \
    --memory-size 256 \
    --description "StockPulse: fetches Polygon.io data and publishes to SQS" \
    --environment "{\"Variables\":{\"POLYGON_SECRET_NAME\":\"$POLYGON_SECRET_NAME\",\"SQS_QUEUE_URL\":\"$SQS_QUEUE_URL\",\"SYMBOLS\":\"$SYMBOLS\"}}" \
    --tags "project-name=StockPulse" \
    --region "$AWS_REGION"
fi

# Grant the ingester role permission to read the secret
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "$POLYGON_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query ARN --output text 2>/dev/null || true)

if [ -n "$SECRET_ARN" ]; then
  aws iam put-role-policy \
    --role-name stockpulse-ingester-role \
    --policy-name SecretsManagerReadPolicy \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": \"secretsmanager:GetSecretValue\",
        \"Resource\": \"$SECRET_ARN\"
      }]
    }"
  echo "  IAM policy granted: ingester-role → $POLYGON_SECRET_NAME"
fi

# Wire up EventBridge rule to ingester
INGESTER_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:stockpulse-ingester"
EVENTBRIDGE_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/stockpulse-eventbridge-role"

aws lambda add-permission \
  --function-name "stockpulse-ingester" \
  --statement-id "EventBridgeInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --source-arn "arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/stockpulse-ingester-schedule" \
  --region "$AWS_REGION" 2>/dev/null || true

aws events put-targets \
  --rule "stockpulse-ingester-schedule" \
  --targets "Id=1,Arn=$INGESTER_ARN,RoleArn=$EVENTBRIDGE_ROLE_ARN" \
  --region "$AWS_REGION"

echo "  Ingester deployed and wired to EventBridge."

# ---------------------------------------------------------------------------
# Step 3: Deploy Lambda Processor
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Packaging Lambda Processor..."

PROCESSOR_DIR="$PROJECT_ROOT/lambda/processor"
PROCESSOR_ZIP="$BUILD_DIR/processor.zip"

(cd "$PROCESSOR_DIR" && zip -r "$PROCESSOR_ZIP" lambda_function.py)
echo "  Packaged: $PROCESSOR_ZIP"

if aws lambda get-function \
    --function-name "stockpulse-processor" \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  echo "  Updating existing processor Lambda..."
  aws lambda update-function-code \
    --function-name "stockpulse-processor" \
    --zip-file "fileb://$PROCESSOR_ZIP" \
    --region "$AWS_REGION"

  aws lambda wait function-updated \
    --function-name "stockpulse-processor" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "stockpulse-processor" \
    --layers "$LAYER_ARN" \
    --environment "{\"Variables\":{\"S3_BUCKET\":\"$S3_BUCKET\"}}" \
    --region "$AWS_REGION"

  aws lambda tag-resource \
    --resource "arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:stockpulse-processor" \
    --tags "project-name=StockPulse" \
    --region "$AWS_REGION"
else
  echo "  Creating processor Lambda..."
  aws lambda create-function \
    --function-name "stockpulse-processor" \
    --runtime python3.11 \
    --role "$PROCESSOR_ROLE" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$PROCESSOR_ZIP" \
    --timeout 120 \
    --memory-size 512 \
    --description "StockPulse: consumes SQS queue, writes Parquet to S3" \
    --layers "$LAYER_ARN" \
    --environment "{\"Variables\":{\"S3_BUCKET\":\"$S3_BUCKET\"}}" \
    --tags "project-name=StockPulse" \
    --region "$AWS_REGION"
fi

# ---------------------------------------------------------------------------
# Step 4: Create SQS Event Source Mapping for Processor
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Configuring SQS event source mapping..."

# Check if mapping already exists
EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
  --function-name "stockpulse-processor" \
  --event-source-arn "$SQS_QUEUE_ARN" \
  --region "$AWS_REGION" \
  --query "EventSourceMappings[0].UUID" \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING_MAPPING" = "None" ] || [ -z "$EXISTING_MAPPING" ]; then
  aws lambda create-event-source-mapping \
    --function-name "stockpulse-processor" \
    --event-source-arn "$SQS_QUEUE_ARN" \
    --batch-size 10 \
    --region "$AWS_REGION"
  echo "  SQS event source mapping created."
else
  echo "  SQS event source mapping already exists (UUID: $EXISTING_MAPPING) — skipping."
fi

echo ""
echo "============================================================"
echo "Lambda deployment complete!"
echo ""
echo "Enable ingester: aws events enable-rule --name stockpulse-ingester-schedule --region $AWS_REGION"
echo "Test ingester:   aws lambda invoke --function-name stockpulse-ingester /tmp/ingester-out.json --region $AWS_REGION && cat /tmp/ingester-out.json"
echo "============================================================"
