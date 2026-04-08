#!/usr/bin/env bash
# StockPulse — Trigger the Glue ETL job and tail its status.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
GLUE_JOB_NAME="stockpulse-ohlcv-transform"

echo "Starting Glue job: $GLUE_JOB_NAME"

RUN_ID=$(aws glue start-job-run \
  --job-name "$GLUE_JOB_NAME" \
  --region "$AWS_REGION" \
  --query JobRunId \
  --output text)

echo "Job run ID: $RUN_ID"
echo "Polling status every 30s (Glue has ~2 min cold start)..."

while true; do
  STATUS=$(aws glue get-job-run \
    --job-name "$GLUE_JOB_NAME" \
    --run-id "$RUN_ID" \
    --region "$AWS_REGION" \
    --query JobRun.JobRunState \
    --output text)

  echo "  $(date '+%H:%M:%S') — $STATUS"

  case "$STATUS" in
    SUCCEEDED) echo "Job completed successfully."; exit 0 ;;
    FAILED|ERROR|TIMEOUT)
      echo "Job failed with state: $STATUS"
      aws glue get-job-run \
        --job-name "$GLUE_JOB_NAME" \
        --run-id "$RUN_ID" \
        --region "$AWS_REGION" \
        --query JobRun.ErrorMessage \
        --output text
      exit 1
      ;;
  esac

  sleep 30
done
