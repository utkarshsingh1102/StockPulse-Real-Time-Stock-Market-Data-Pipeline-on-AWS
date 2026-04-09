#!/usr/bin/env bash
# =============================================================================
# StockPulse — Resume Services
# Restores all paused AWS resources back to active state.
#
# What this resumes:
#   - Kinesis stream recreated → 1 shard (same as original)
#   - Lambda concurrency       → removes the 0-concurrency block on both functions
#   - EventBridge rule         → re-enabled (triggers ingester every 5 minutes)
#
# Usage:
#   ./scripts/resume_services.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
KINESIS_STREAM="${KINESIS_STREAM:-stockpulse-stream}"
LAMBDA_INGESTER_NAME="${LAMBDA_INGESTER_NAME:-stockpulse-ingester}"
LAMBDA_PROCESSOR_NAME="${LAMBDA_PROCESSOR_NAME:-stockpulse-processor}"

echo "============================================================"
echo "StockPulse — Resuming Services"
echo "Region: $AWS_REGION"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Recreate Kinesis stream
# ---------------------------------------------------------------------------
echo ""
echo "[1/3] Recreating Kinesis stream..."

if aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  echo "  Kinesis stream '$KINESIS_STREAM' already exists — skipping."
else
  aws kinesis create-stream \
    --stream-name "$KINESIS_STREAM" \
    --shard-count 1 \
    --region "$AWS_REGION"

  echo "  Waiting for stream to become active..."
  aws kinesis wait stream-exists \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION"

  aws kinesis add-tags-to-stream \
    --stream-name "$KINESIS_STREAM" \
    --tags project-name=StockPulse \
    --region "$AWS_REGION"

  echo "  Kinesis stream '$KINESIS_STREAM' recreated."
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
  echo "  EventBridge rule enabled — ingester will trigger every 5 minutes (market hours)." || \
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
echo "    /tmp/ingester-out.json --region $AWS_REGION \\"
echo "    --cli-read-timeout 0 && cat /tmp/ingester-out.json"
echo ""
echo "To pause again: ./scripts/pause_services.sh"
echo "============================================================"
