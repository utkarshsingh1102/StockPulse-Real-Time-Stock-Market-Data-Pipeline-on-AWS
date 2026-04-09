#!/usr/bin/env bash
# =============================================================================
# StockPulse — Pause Services
# Stops all active/billable AWS resources to minimise costs.
#
# What this pauses:
#   - EventBridge rule       → stops Lambda from being triggered every 5 minutes
#   - Lambda concurrency = 0 → hard blocks any invocations on both functions
#   - Kinesis stream deleted → ~$0.015/shard/hour — only cost worth eliminating
#
# What is unaffected (negligible or zero at-rest cost):
#   - S3 buckets             → storage cost only (~$0.023/GB/month)
#   - SQS DLQ               → pay per message, $0 when idle
#   - SNS                   → pay per message, $0 when idle
#   - CloudWatch alarms     → minimal fixed cost
#   - Secrets Manager       → ~$0.40/secret/month
#
# Usage:
#   ./scripts/pause_services.sh
#
# Resume with:
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
echo "StockPulse — Pausing Services"
echo "Region: $AWS_REGION"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Disable EventBridge rule — stops Lambda being triggered every 5 minutes
# ---------------------------------------------------------------------------
echo ""
echo "[1/3] Disabling EventBridge schedule..."

aws events disable-rule \
  --name "stockpulse-ingester-schedule" \
  --region "$AWS_REGION" 2>/dev/null && \
  echo "  EventBridge rule disabled." || \
  echo "  EventBridge rule not found — skipping."

# ---------------------------------------------------------------------------
# 2. Set Lambda reserved concurrency to 0 — hard blocks all invocations
# ---------------------------------------------------------------------------
echo ""
echo "[2/3] Blocking Lambda invocations (concurrency = 0)..."

for fn in "$LAMBDA_INGESTER_NAME" "$LAMBDA_PROCESSOR_NAME"; do
  aws lambda put-function-concurrency \
    --function-name "$fn" \
    --reserved-concurrent-executions 0 \
    --region "$AWS_REGION" 2>/dev/null && \
    echo "  $fn → concurrency set to 0." || \
    echo "  $fn not found — skipping."
done

# ---------------------------------------------------------------------------
# 3. Delete Kinesis stream — eliminates ~$0.015/shard/hour charge
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] Deleting Kinesis stream..."

aws kinesis delete-stream \
  --stream-name "$KINESIS_STREAM" \
  --region "$AWS_REGION" 2>/dev/null && \
  echo "  Kinesis stream '$KINESIS_STREAM' deleted." || \
  echo "  Kinesis stream not found — skipping."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "Services paused."
echo ""
echo "Lambda and EventBridge have zero at-rest cost when paused."
echo "Kinesis stream deleted — recreated automatically on resume."
echo "S3 storage costs continue (~\$0.023/GB/month)."
echo "SQS/SNS/Secrets Manager costs are negligible when idle."
echo ""
echo "To resume: ./scripts/resume_services.sh"
echo "============================================================"
