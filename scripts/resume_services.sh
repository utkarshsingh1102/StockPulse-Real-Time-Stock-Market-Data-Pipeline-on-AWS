#!/usr/bin/env bash
# =============================================================================
# StockPulse — Resume Services
# Restores all paused AWS resources back to active state.
#
# What this resumes:
#   - Kinesis stream         → recreated with same config (1 shard, SSE, tags)
#   - Lambda concurrency     → removes the 0-concurrency block on both functions
#   - EventBridge rule       → re-enabled (triggers ingester every minute)
#
# Usage:
#   ./scripts/resume_services.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
LAMBDA_INGESTER_NAME="${LAMBDA_INGESTER_NAME:-stockpulse-ingester}"
LAMBDA_PROCESSOR_NAME="${LAMBDA_PROCESSOR_NAME:-stockpulse-processor}"
KINESIS_STREAM="${KINESIS_STREAM:-stockpulse-stream}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "============================================================"
echo "StockPulse — Resuming Services"
echo "Region: $AWS_REGION"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Recreate Kinesis stream (deleted during pause to save cost)
# ---------------------------------------------------------------------------
echo ""
echo "[1/3] Recreating Kinesis stream '$KINESIS_STREAM'..."

if aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" 2>/dev/null; then
  echo "  Stream already exists — skipping."
else
  aws kinesis create-stream \
    --stream-name "$KINESIS_STREAM" \
    --shard-count 1 \
    --region "$AWS_REGION"

  echo "  Waiting for stream to become ACTIVE..."
  aws kinesis wait stream-exists \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION"

  aws kinesis start-stream-encryption \
    --stream-name "$KINESIS_STREAM" \
    --encryption-type KMS \
    --key-id alias/aws/kinesis \
    --region "$AWS_REGION"

  aws kinesis add-tags-to-stream \
    --stream-name "$KINESIS_STREAM" \
    --tags project-name=StockPulse \
    --region "$AWS_REGION"

  echo "  Kinesis stream recreated (1 shard, SSE enabled, tagged)."
fi

# Reattach Kinesis as event source for processor Lambda (may already exist)
echo "  Checking Kinesis event source mapping..."
KINESIS_ARN="arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID:stream/$KINESIS_STREAM"
DLQ_ARN="arn:aws:sqs:$AWS_REGION:$ACCOUNT_ID:${DLQ_NAME:-stockpulse-dlq}"

EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_PROCESSOR_NAME" \
  --event-source-arn "$KINESIS_ARN" \
  --region "$AWS_REGION" \
  --query "EventSourceMappings[0].UUID" \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING_MAPPING" = "None" ] || [ -z "$EXISTING_MAPPING" ]; then
  aws lambda create-event-source-mapping \
    --function-name "$LAMBDA_PROCESSOR_NAME" \
    --event-source-arn "$KINESIS_ARN" \
    --batch-size 100 \
    --starting-position LATEST \
    --destination-config "OnFailure={Destination=$DLQ_ARN}" \
    --bisect-batch-on-function-error \
    --region "$AWS_REGION"
  echo "  Kinesis event source mapping recreated."
else
  echo "  Kinesis event source mapping already exists — skipping."
fi

# ---------------------------------------------------------------------------
# 2. Remove Lambda concurrency block
# ---------------------------------------------------------------------------
echo ""
echo "[2/3] Restoring Lambda concurrency..."

for fn in "$LAMBDA_INGESTER_NAME" "$LAMBDA_PROCESSOR_NAME"; do
  aws lambda delete-function-concurrency \
    --function-name "$fn" \
    --region "$AWS_REGION" 2>/dev/null && \
    echo "  $fn → concurrency limit removed." || \
    echo "  $fn not found — skipping."
done

# ---------------------------------------------------------------------------
# 3. Re-enable EventBridge rule
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] Enabling EventBridge schedule..."

aws events enable-rule \
  --name "stockpulse-ingester-schedule" \
  --region "$AWS_REGION" 2>/dev/null && \
  echo "  EventBridge rule enabled — ingester will trigger every minute (market hours)." || \
  echo "  EventBridge rule not found — skipping."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "Services resumed. Pipeline is live."
echo ""
echo "Test ingester manually:"
echo "  aws lambda invoke --function-name $LAMBDA_INGESTER_NAME \\"
echo "    /tmp/ingester-out.json --region $AWS_REGION && cat /tmp/ingester-out.json"
echo ""
echo "To pause again: ./scripts/pause_services.sh"
echo "============================================================"
