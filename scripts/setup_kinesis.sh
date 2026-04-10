#!/usr/bin/env bash
# =============================================================================
# StockPulse — Kinesis Setup & Pipeline Verification
#
# Run this after deleting the Kinesis stream to restore it and verify
# that every component in the pipeline is correctly wired up.
#
# Usage:
#   chmod +x scripts/setup_kinesis.sh
#   ./scripts/setup_kinesis.sh
#
# What it does:
#   1. Creates stockpulse-stream (1 shard)
#   2. Re-wires processor Lambda event source mapping
#   3. Verifies every pipeline component end-to-end
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
KINESIS_STREAM="${KINESIS_STREAM:-stockpulse-stream}"
S3_BUCKET="${S3_BUCKET:-stockpulse-data-us2}"
S3_SCRIPTS_BUCKET="${S3_SCRIPTS_BUCKET:-stockpulse-scripts-us2}"
KINESIS_STREAM_ARN="arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID:stream/$KINESIS_STREAM"

PASS="✅"
FAIL="❌"
WARN="⚠️ "

# Counters
CHECKS=0
FAILURES=0

check() {
    local label="$1"
    local result="$2"   # "ok" or "fail"
    local detail="$3"
    CHECKS=$((CHECKS + 1))
    if [ "$result" = "ok" ]; then
        printf "  %s  %-55s %s\n" "$PASS" "$label" "$detail"
    else
        printf "  %s  %-55s %s\n" "$FAIL" "$label" "$detail"
        FAILURES=$((FAILURES + 1))
    fi
}

warn() {
    printf "  %s  %s\n" "$WARN" "$1"
}

divider() {
    echo ""
    echo "─────────────────────────────────────────────────────────────────"
    echo "  $1"
    echo "─────────────────────────────────────────────────────────────────"
}

echo ""
echo "============================================================"
echo "  StockPulse — Kinesis Setup & Pipeline Verification"
echo "  Region:  $AWS_REGION"
echo "  Account: $ACCOUNT_ID"
echo "============================================================"

# =============================================================================
# STEP 1: Create Kinesis stream
# =============================================================================
divider "STEP 1 — Kinesis Stream"

STREAM_STATUS=$(aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" \
    --query "StreamDescriptionSummary.StreamStatus" \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$STREAM_STATUS" = "NOT_FOUND" ]; then
    echo "  Stream not found — creating $KINESIS_STREAM (1 shard)..."
    aws kinesis create-stream \
        --stream-name "$KINESIS_STREAM" \
        --shard-count 1 \
        --region "$AWS_REGION"

    aws kinesis add-tags-to-stream \
        --stream-name "$KINESIS_STREAM" \
        --tags "project-name=StockPulse" \
        --region "$AWS_REGION"

    echo "  Waiting for stream to become ACTIVE..."
    aws kinesis wait stream-exists \
        --stream-name "$KINESIS_STREAM" \
        --region "$AWS_REGION"
    echo "  Stream created and ACTIVE."
elif [ "$STREAM_STATUS" = "ACTIVE" ]; then
    echo "  Stream already ACTIVE — skipping creation."
else
    echo "  Stream exists but status is $STREAM_STATUS — waiting for ACTIVE..."
    aws kinesis wait stream-exists \
        --stream-name "$KINESIS_STREAM" \
        --region "$AWS_REGION"
fi

# =============================================================================
# STEP 2: Re-wire processor Lambda event source mapping
# =============================================================================
divider "STEP 2 — Kinesis → Processor Lambda ESM"

EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
    --function-name "stockpulse-processor" \
    --event-source-arn "$KINESIS_STREAM_ARN" \
    --region "$AWS_REGION" \
    --query "EventSourceMappings[0].UUID" \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_MAPPING" = "None" ] || [ -z "$EXISTING_MAPPING" ]; then
    echo "  No event source mapping found — creating..."
    aws lambda create-event-source-mapping \
        --function-name "stockpulse-processor" \
        --event-source-arn "$KINESIS_STREAM_ARN" \
        --batch-size 100 \
        --starting-position LATEST \
        --region "$AWS_REGION" > /dev/null
    echo "  Event source mapping created (batch size: 100, position: LATEST)."
else
    echo "  Event source mapping already exists (UUID: $EXISTING_MAPPING) — skipping."
fi

# =============================================================================
# STEP 3: Full pipeline verification
# =============================================================================
divider "STEP 3 — Pipeline Verification"
echo ""

# --- Kinesis ---
echo "  [Kinesis]"
STREAM_STATE=$(aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" \
    --query "StreamDescriptionSummary.StreamStatus" \
    --output text 2>/dev/null || echo "MISSING")
SHARD_COUNT=$(aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" \
    --query "StreamDescriptionSummary.OpenShardCount" \
    --output text 2>/dev/null || echo "0")
[ "$STREAM_STATE" = "ACTIVE" ] \
    && check "Kinesis stream: $KINESIS_STREAM" "ok" "ACTIVE | shards=$SHARD_COUNT" \
    || check "Kinesis stream: $KINESIS_STREAM" "fail" "status=$STREAM_STATE"

# --- Lambda: ingester ---
echo ""
echo "  [Lambda: Ingester]"
INGESTER_STATE=$(aws lambda get-function \
    --function-name "stockpulse-ingester" \
    --region "$AWS_REGION" \
    --query "Configuration.State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$INGESTER_STATE" = "Active" ] \
    && check "stockpulse-ingester exists" "ok" "State=Active" \
    || check "stockpulse-ingester exists" "fail" "State=$INGESTER_STATE"

INGESTER_STREAM=$(aws lambda get-function-configuration \
    --function-name "stockpulse-ingester" \
    --region "$AWS_REGION" \
    --query "Environment.Variables.KINESIS_STREAM_NAME" \
    --output text 2>/dev/null || echo "MISSING")
[ "$INGESTER_STREAM" = "$KINESIS_STREAM" ] \
    && check "Ingester env KINESIS_STREAM_NAME" "ok" "$INGESTER_STREAM" \
    || check "Ingester env KINESIS_STREAM_NAME" "fail" "got=$INGESTER_STREAM expected=$KINESIS_STREAM"

INGESTER_SCHEDULE=$(aws events list-targets-by-rule \
    --rule "stockpulse-ingester-schedule" \
    --region "$AWS_REGION" \
    --query "Targets[?contains(Arn, 'stockpulse-ingester')].Arn" \
    --output text 2>/dev/null || echo "")
[ -n "$INGESTER_SCHEDULE" ] \
    && check "EventBridge → ingester wired" "ok" "rule=stockpulse-ingester-schedule" \
    || check "EventBridge → ingester wired" "fail" "no target found"

INGESTER_RULE_STATE=$(aws events describe-rule \
    --name "stockpulse-ingester-schedule" \
    --region "$AWS_REGION" \
    --query "State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$INGESTER_RULE_STATE" = "ENABLED" ] \
    && check "Ingester EventBridge rule enabled" "ok" "ENABLED" \
    || { [ "$INGESTER_RULE_STATE" = "DISABLED" ] \
        && check "Ingester EventBridge rule enabled" "fail" "DISABLED — run: aws events enable-rule --name stockpulse-ingester-schedule" \
        || check "Ingester EventBridge rule enabled" "fail" "state=$INGESTER_RULE_STATE"; }

# --- Lambda: processor ---
echo ""
echo "  [Lambda: Processor]"
PROCESSOR_STATE=$(aws lambda get-function \
    --function-name "stockpulse-processor" \
    --region "$AWS_REGION" \
    --query "Configuration.State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$PROCESSOR_STATE" = "Active" ] \
    && check "stockpulse-processor exists" "ok" "State=Active" \
    || check "stockpulse-processor exists" "fail" "State=$PROCESSOR_STATE"

ESM_STATE=$(aws lambda list-event-source-mappings \
    --function-name "stockpulse-processor" \
    --event-source-arn "$KINESIS_STREAM_ARN" \
    --region "$AWS_REGION" \
    --query "EventSourceMappings[0].State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$ESM_STATE" = "Enabled" ] \
    && check "Kinesis → processor ESM" "ok" "State=Enabled" \
    || check "Kinesis → processor ESM" "fail" "State=$ESM_STATE"

PROCESSOR_BUCKET=$(aws lambda get-function-configuration \
    --function-name "stockpulse-processor" \
    --region "$AWS_REGION" \
    --query "Environment.Variables.S3_BUCKET" \
    --output text 2>/dev/null || echo "MISSING")
[ "$PROCESSOR_BUCKET" = "$S3_BUCKET" ] \
    && check "Processor env S3_BUCKET" "ok" "$PROCESSOR_BUCKET" \
    || check "Processor env S3_BUCKET" "fail" "got=$PROCESSOR_BUCKET expected=$S3_BUCKET"

# --- S3 buckets ---
echo ""
echo "  [S3]"
aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null \
    && check "Data bucket: $S3_BUCKET" "ok" "accessible" \
    || check "Data bucket: $S3_BUCKET" "fail" "not accessible"

aws s3api head-bucket --bucket "$S3_SCRIPTS_BUCKET" --region "$AWS_REGION" 2>/dev/null \
    && check "Scripts bucket: $S3_SCRIPTS_BUCKET" "ok" "accessible" \
    || check "Scripts bucket: $S3_SCRIPTS_BUCKET" "fail" "not accessible"

RAW_COUNT=$(aws s3 ls "s3://$S3_BUCKET/raw/" --recursive --region "$AWS_REGION" 2>/dev/null | wc -l | tr -d ' ')
PROCESSED_COUNT=$(aws s3 ls "s3://$S3_BUCKET/processed/" --recursive --region "$AWS_REGION" 2>/dev/null | wc -l | tr -d ' ')
check "S3 raw/ has data" "$([ "$RAW_COUNT" -gt 0 ] && echo ok || echo fail)" "$RAW_COUNT parquet files"
check "S3 processed/ has data" "$([ "$PROCESSED_COUNT" -gt 0 ] && echo ok || echo fail)" "$PROCESSED_COUNT parquet files"

# --- Glue ---
echo ""
echo "  [Glue]"
GLUE_JOB=$(aws glue get-job \
    --job-name "stockpulse-ohlcv-transform" \
    --region "$AWS_REGION" \
    --query "Job.Name" \
    --output text 2>/dev/null || echo "MISSING")
[ "$GLUE_JOB" = "stockpulse-ohlcv-transform" ] \
    && check "Glue job: stockpulse-ohlcv-transform" "ok" "exists" \
    || check "Glue job: stockpulse-ohlcv-transform" "fail" "not found"

TRIGGER_STATE=$(aws glue get-trigger \
    --name "stockpulse-daily-transform" \
    --region "$AWS_REGION" \
    --query "Trigger.State" \
    --output text 2>/dev/null || echo "MISSING")
TRIGGER_SCHEDULE=$(aws glue get-trigger \
    --name "stockpulse-daily-transform" \
    --region "$AWS_REGION" \
    --query "Trigger.Schedule" \
    --output text 2>/dev/null || echo "")
[ "$TRIGGER_STATE" = "ACTIVATED" ] \
    && check "Glue trigger: stockpulse-daily-transform" "ok" "ACTIVATED | $TRIGGER_SCHEDULE" \
    || check "Glue trigger: stockpulse-daily-transform" "fail" "State=$TRIGGER_STATE"

GLUE_LAST_RUN=$(aws glue get-job-runs \
    --job-name "stockpulse-ohlcv-transform" \
    --region "$AWS_REGION" \
    --max-results 1 \
    --query "JobRuns[0].{Status:JobRunState,Started:StartedOn}" \
    --output text 2>/dev/null || echo "NO_RUNS")
check "Glue last run" "ok" "$GLUE_LAST_RUN"

# --- EventBridge (Glue → redshift-loader) ---
echo ""
echo "  [EventBridge: Glue → Redshift Loader]"
EB_RULE_STATE=$(aws events describe-rule \
    --name "stockpulse-glue-succeeded" \
    --region "$AWS_REGION" \
    --query "State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$EB_RULE_STATE" = "ENABLED" ] \
    && check "EventBridge rule: stockpulse-glue-succeeded" "ok" "ENABLED" \
    || check "EventBridge rule: stockpulse-glue-succeeded" "fail" "State=$EB_RULE_STATE"

EB_TARGET=$(aws events list-targets-by-rule \
    --rule "stockpulse-glue-succeeded" \
    --region "$AWS_REGION" \
    --query "Targets[?contains(Arn, 'stockpulse-redshift-loader')].Arn" \
    --output text 2>/dev/null || echo "")
[ -n "$EB_TARGET" ] \
    && check "EventBridge → redshift-loader wired" "ok" "target connected" \
    || check "EventBridge → redshift-loader wired" "fail" "no target found"

# --- Lambda: redshift-loader ---
echo ""
echo "  [Lambda: Redshift Loader]"
LOADER_STATE=$(aws lambda get-function \
    --function-name "stockpulse-redshift-loader" \
    --region "$AWS_REGION" \
    --query "Configuration.State" \
    --output text 2>/dev/null || echo "MISSING")
[ "$LOADER_STATE" = "Active" ] \
    && check "stockpulse-redshift-loader exists" "ok" "State=Active" \
    || check "stockpulse-redshift-loader exists" "fail" "State=$LOADER_STATE"

LOADER_INVOKE_PERM=$(aws lambda get-policy \
    --function-name "stockpulse-redshift-loader" \
    --region "$AWS_REGION" \
    --query "Policy" \
    --output text 2>/dev/null | python3 -c "
import sys, json
try:
    policy = json.loads(sys.stdin.read())
    stmts = policy.get('Statement', [])
    ok = any('events.amazonaws.com' in str(s.get('Principal','')) for s in stmts)
    print('ok' if ok else 'fail')
except:
    print('fail')
")
[ "$LOADER_INVOKE_PERM" = "ok" ] \
    && check "EventBridge invoke permission on redshift-loader" "ok" "events.amazonaws.com allowed" \
    || check "EventBridge invoke permission on redshift-loader" "fail" "missing invoke permission"

LOADER_ROLE=$(aws lambda get-function \
    --function-name "stockpulse-redshift-loader" \
    --region "$AWS_REGION" \
    --query "Configuration.Role" \
    --output text 2>/dev/null || echo "")
LOADER_ROLE_NAME=$(echo "$LOADER_ROLE" | awk -F'/' '{print $NF}')
REDSHIFT_POLICY=$(aws iam list-attached-role-policies \
    --role-name "$LOADER_ROLE_NAME" \
    --region "$AWS_REGION" \
    --query "AttachedPolicies[?PolicyName=='AmazonRedshiftDataFullAccess'].PolicyName" \
    --output text 2>/dev/null || echo "")
[ -n "$REDSHIFT_POLICY" ] \
    && check "AmazonRedshiftDataFullAccess on loader role" "ok" "role=$LOADER_ROLE_NAME" \
    || check "AmazonRedshiftDataFullAccess on loader role" "fail" "role=$LOADER_ROLE_NAME missing policy"

# Check redshift-loader workgroup env var matches actual workgroup
ACTUAL_WG=$(aws redshift-serverless list-workgroups \
    --region "$AWS_REGION" \
    --query "workgroups[0].workgroupName" \
    --output text 2>/dev/null || echo "MISSING")
LOADER_WG=$(aws lambda get-function-configuration \
    --function-name "stockpulse-redshift-loader" \
    --region "$AWS_REGION" \
    --query "Environment.Variables.REDSHIFT_WORKGROUP" \
    --output text 2>/dev/null || echo "MISSING")
[ "$LOADER_WG" = "$ACTUAL_WG" ] \
    && check "Loader REDSHIFT_WORKGROUP matches actual workgroup" "ok" "$LOADER_WG" \
    || check "Loader REDSHIFT_WORKGROUP matches actual workgroup" "fail" "loader=$LOADER_WG actual=$ACTUAL_WG"

# Check GetCredentials permission on loader role
GET_CREDS=$(aws iam get-role-policy \
    --role-name "$LOADER_ROLE_NAME" \
    --policy-name "RedshiftServerlessCredentials" \
    --region "$AWS_REGION" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok')" 2>/dev/null || echo "fail")
[ "$GET_CREDS" = "ok" ] \
    && check "redshift-serverless:GetCredentials on loader role" "ok" "policy=RedshiftServerlessCredentials" \
    || check "redshift-serverless:GetCredentials on loader role" "fail" "missing — run: aws iam put-role-policy --role-name $LOADER_ROLE_NAME --policy-name RedshiftServerlessCredentials"

# --- Redshift Serverless ---
echo ""
echo "  [Redshift Serverless]"
RS_WG=$(aws redshift-serverless get-workgroup \
    --workgroup-name "stockpulse-wq" \
    --region "$AWS_REGION" \
    --query "workgroup.status" \
    --output text 2>/dev/null | tr -d '[:space:]' || echo "MISSING")
[ "$RS_WG" = "AVAILABLE" ] \
    && check "Redshift workgroup: stockpulse-wq" "ok" "$RS_WG" \
    || check "Redshift workgroup: stockpulse-wq" "fail" "status=$RS_WG"

RS_NS=$(aws redshift-serverless get-namespace \
    --namespace-name "stockpulse-ns" \
    --region "$AWS_REGION" \
    --query "namespace.status" \
    --output text 2>/dev/null || echo "MISSING")
[ "$RS_NS" = "AVAILABLE" ] \
    && check "Redshift namespace: stockpulse-ns" "ok" "AVAILABLE" \
    || check "Redshift namespace: stockpulse-ns" "fail" "status=$RS_NS"

# --- Secrets Manager ---
echo ""
echo "  [Secrets Manager]"
SECRET_STATUS=$(aws secretsmanager describe-secret \
    --secret-id "stockpulse/polygon-api-key" \
    --region "$AWS_REGION" \
    --query "Name" \
    --output text 2>/dev/null || echo "MISSING")
[ "$SECRET_STATUS" != "MISSING" ] \
    && check "Secret: stockpulse/polygon-api-key" "ok" "exists" \
    || check "Secret: stockpulse/polygon-api-key" "fail" "not found"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "  Summary: $((CHECKS - FAILURES))/$CHECKS checks passed"
if [ "$FAILURES" -eq 0 ]; then
    echo "  $PASS Pipeline fully operational — nothing to fix."
else
    echo "  $FAIL $FAILURES check(s) failed — review items above."
fi
echo "─────────────────────────────────────────────────────────────────"
echo ""
