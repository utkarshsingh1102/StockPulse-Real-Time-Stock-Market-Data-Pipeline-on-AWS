#!/usr/bin/env bash
# =============================================================================
# StockPulse — Resume Services
# Restores all paused AWS resources back to active state.
#
# What this resumes:
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

echo "============================================================"
echo "StockPulse — Resuming Services"
echo "Region: $AWS_REGION"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Remove Lambda concurrency block
# ---------------------------------------------------------------------------
echo ""
echo "[1/2] Restoring Lambda concurrency..."

for fn in "$LAMBDA_INGESTER_NAME" "$LAMBDA_PROCESSOR_NAME"; do
  aws lambda delete-function-concurrency \
    --function-name "$fn" \
    --region "$AWS_REGION" 2>/dev/null && \
    echo "  $fn → concurrency limit removed." || \
    echo "  $fn not found — skipping."
done

# ---------------------------------------------------------------------------
# 2. Re-enable EventBridge rule
# ---------------------------------------------------------------------------
echo ""
echo "[2/2] Enabling EventBridge schedule..."

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
