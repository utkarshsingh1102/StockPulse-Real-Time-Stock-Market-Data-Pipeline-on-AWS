#!/usr/bin/env bash
# =============================================================================
# StockPulse — Deploy Orchestrator Lambda
#
# Creates/updates the orchestrator Lambda and wires it to EventBridge
# to run daily at 3:45 PM ET (19:45 UTC) Mon-Fri.
#
# The orchestrator:
#   1. Creates Kinesis stream
#   2. Waits for ACTIVE
#   3. Invokes ingester Lambda (synchronous)
#   4. Waits 90s for processor to flush to S3
#   5. Deletes Kinesis stream
#
# Usage:
#   chmod +x scripts/deploy_orchestrator.sh
#   ./scripts/deploy_orchestrator.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
KINESIS_STREAM="${KINESIS_STREAM:-stockpulse-stream}"
PROCESSOR_ROLE="arn:aws:iam::$ACCOUNT_ID:role/stockpulse-processor-role"
BUILD_DIR="$PROJECT_ROOT/.build"
FUNCTION_NAME="stockpulse-orchestrator"
RULE_NAME="stockpulse-orchestrator-schedule"

mkdir -p "$BUILD_DIR"

echo "============================================================"
echo "  StockPulse — Orchestrator Deployment"
echo "  Region:  $AWS_REGION | Account: $ACCOUNT_ID"
echo "============================================================"

# ---------------------------------------------------------------------------
# Step 1: Package Lambda
# ---------------------------------------------------------------------------
echo ""
echo "[1/5] Packaging orchestrator Lambda..."

ORCHESTRATOR_ZIP="$BUILD_DIR/orchestrator.zip"
(cd "$PROJECT_ROOT/lambda/orchestrator" && zip -r "$ORCHESTRATOR_ZIP" lambda_function.py)
echo "  Packaged: $ORCHESTRATOR_ZIP"

# ---------------------------------------------------------------------------
# Step 2: Grant processor role Kinesis + Lambda invoke permissions
# ---------------------------------------------------------------------------
echo ""
echo "[2/5] Ensuring IAM permissions on stockpulse-processor-role..."

# Kinesis + Glue + S3 + Lambda invoke permissions
aws iam put-role-policy \
  --role-name stockpulse-processor-role \
  --policy-name OrchestratorKinesisPolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"kinesis:CreateStream\",
          \"kinesis:DeleteStream\",
          \"kinesis:DescribeStreamSummary\",
          \"kinesis:AddTagsToStream\"
        ],
        \"Resource\": \"arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID:stream/$KINESIS_STREAM\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"lambda:InvokeFunction\",
        \"Resource\": \"arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:stockpulse-ingester\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"glue:StartJobRun\",
        \"Resource\": \"arn:aws:glue:$AWS_REGION:$ACCOUNT_ID:job/stockpulse-ohlcv-transform\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:ListBucket\", \"s3:GetObject\"],
        \"Resource\": [
          \"arn:aws:s3:::$S3_BUCKET\",
          \"arn:aws:s3:::$S3_BUCKET/*\"
        ]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"cloudwatch:PutMetricData\",
        \"Resource\": \"*\"
      }
    ]
  }"
echo "  IAM policy updated."

# ---------------------------------------------------------------------------
# Step 3: Deploy Lambda
# ---------------------------------------------------------------------------
echo ""
echo "[3/5] Deploying orchestrator Lambda..."

S3_INPUT_PATH="s3://$S3_BUCKET/raw/"
S3_OUTPUT_PATH="s3://$S3_BUCKET/processed/"

ENV_VARS="{\"Variables\":{\
\"KINESIS_STREAM\":\"$KINESIS_STREAM\",\
\"INGESTER_FUNCTION\":\"stockpulse-ingester\",\
\"GLUE_JOB_NAME\":\"stockpulse-ohlcv-transform\",\
\"S3_INPUT_PATH\":\"$S3_INPUT_PATH\",\
\"S3_OUTPUT_PATH\":\"$S3_OUTPUT_PATH\",\
\"STACK_REGION\":\"$AWS_REGION\",\
\"PROCESSOR_FLUSH_WAIT\":\"90\"\
}}"

if aws lambda get-function \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  echo "  Updating existing Lambda..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ORCHESTRATOR_ZIP" \
    --region "$AWS_REGION" > /dev/null

  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout 600 \
    --environment "$ENV_VARS" \
    --region "$AWS_REGION" > /dev/null
else
  echo "  Creating Lambda..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.11 \
    --role "$PROCESSOR_ROLE" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$ORCHESTRATOR_ZIP" \
    --timeout 600 \
    --memory-size 256 \
    --description "StockPulse: daily Kinesis lifecycle + ingester orchestration" \
    --environment "$ENV_VARS" \
    --tags "project-name=StockPulse" \
    --region "$AWS_REGION" > /dev/null
fi

aws lambda tag-resource \
  --resource "arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$FUNCTION_NAME" \
  --tags "project-name=StockPulse" \
  --region "$AWS_REGION" 2>/dev/null || true

echo "  Lambda deployed."

# ---------------------------------------------------------------------------
# Step 4: Create/update EventBridge rule (3:45 PM ET = 19:45 UTC)
# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Wiring EventBridge schedule (3:45 PM ET Mon-Fri)..."

aws events put-rule \
  --name "$RULE_NAME" \
  --schedule-expression "cron(45 19 ? * MON-FRI *)" \
  --description "StockPulse: trigger orchestrator at 3:45 PM ET daily" \
  --state ENABLED \
  --region "$AWS_REGION" > /dev/null

ORCHESTRATOR_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$FUNCTION_NAME"

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "EventBridgeInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --source-arn "arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$RULE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

aws events put-targets \
  --rule "$RULE_NAME" \
  --targets "Id=1,Arn=$ORCHESTRATOR_ARN" \
  --region "$AWS_REGION" > /dev/null

echo "  EventBridge rule active."

# ---------------------------------------------------------------------------
# Step 5: Disable old ingester-schedule + Glue scheduled trigger
# Orchestrator now owns both — no need for independent schedules
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Disabling old scheduled triggers (orchestrator owns the schedule now)..."

aws events disable-rule \
  --name "stockpulse-ingester-schedule" \
  --region "$AWS_REGION" 2>/dev/null \
  && echo "  Disabled stockpulse-ingester-schedule." \
  || echo "  stockpulse-ingester-schedule not found — skipping."

aws glue stop-trigger \
  --name "stockpulse-daily-transform" \
  --region "$AWS_REGION" 2>/dev/null \
  && echo "  Deactivated Glue trigger stockpulse-daily-transform." \
  || echo "  Glue trigger not found or already stopped — skipping."

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo ""
echo "  Daily schedule: 3:45 PM ET (Mon-Fri)"
echo "  Flow: Orchestrator → Kinesis → Ingester → S3 → [delete Kinesis]"
echo "        → 5:00 PM Glue → 5:15 PM Redshift → Grafana"
echo ""
echo "  Test manually:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME \\"
echo "    --region $AWS_REGION --cli-read-timeout 0 /tmp/orch-out.json \\"
echo "    && cat /tmp/orch-out.json"
echo "============================================================"
