#!/usr/bin/env bash
# StockPulse — Upload Glue PySpark script to S3 and create/update the Glue job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env (gitignored) — keeps config out of version control.
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_SCRIPTS_BUCKET="${S3_SCRIPTS_BUCKET:-stockpulse-scripts-us}"
S3_BUCKET="${S3_BUCKET:-stockpulse-data-us}"
GLUE_JOB_NAME="${GLUE_JOB_NAME:-stockpulse-ohlcv-transform}"
GLUE_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/stockpulse-glue-role"
GLUE_SCRIPT="$PROJECT_ROOT/glue/ohlcv_transform.py"
S3_SCRIPT_PATH="s3://$S3_SCRIPTS_BUCKET/glue/ohlcv_transform.py"

echo "[1/2] Uploading Glue script to $S3_SCRIPT_PATH..."
aws s3 cp "$GLUE_SCRIPT" "$S3_SCRIPT_PATH"
echo "  Uploaded."

echo "[2/2] Creating/updating Glue job '$GLUE_JOB_NAME'..."

JOB_ARGS="{
  \"--job-bookmark-option\": \"job-bookmark-enable\",
  \"--S3_INPUT_PATH\": \"s3://$S3_BUCKET/raw/\",
  \"--S3_OUTPUT_PATH\": \"s3://$S3_BUCKET/processed/\",
  \"--enable-metrics\": \"\",
  \"--enable-continuous-cloudwatch-log\": \"true\"
}"

if aws glue get-job --job-name "$GLUE_JOB_NAME" --region "$AWS_REGION" 2>/dev/null; then
  aws glue update-job \
    --job-name "$GLUE_JOB_NAME" \
    --job-update "Role=$GLUE_ROLE_ARN,\
Command={Name=glueetl,ScriptLocation=$S3_SCRIPT_PATH,PythonVersion=3},\
GlueVersion=4.0,\
WorkerType=G.1X,\
NumberOfWorkers=2,\
Timeout=60,\
DefaultArguments=$JOB_ARGS" \
    --region "$AWS_REGION"
  echo "  Glue job updated."
else
  aws glue create-job \
    --name "$GLUE_JOB_NAME" \
    --role "$GLUE_ROLE_ARN" \
    --command "Name=glueetl,ScriptLocation=$S3_SCRIPT_PATH,PythonVersion=3" \
    --glue-version "4.0" \
    --worker-type "G.1X" \
    --number-of-workers 2 \
    --timeout 60 \
    --default-arguments "$JOB_ARGS" \
    --description "StockPulse: transforms raw tick Parquet to clean OHLCV aggregates" \
    --region "$AWS_REGION"
  echo "  Glue job created."
fi

echo ""
echo "Done. Run the job with: ./scripts/run_glue_job.sh"
