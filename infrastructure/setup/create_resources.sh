#!/usr/bin/env bash
# =============================================================================
# StockPulse — AWS Resource Setup Script
# Creates all AWS infrastructure required for the StockPulse pipeline.
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Sufficient IAM permissions to create the resources below
#
# Usage:
#   export AWS_REGION=us-east-1
#   export POLYGON_API_KEY=your_polygon_key_here
#   chmod +x create_resources.sh && ./create_resources.sh
#
# Resources created:
#   S3 bucket, IAM roles/policies, Kinesis stream, SQS DLQ,
#   SNS topic, CloudWatch alarms, Glue database, EventBridge rule
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Load .env (gitignored) so secrets and config are never hardcoded here.
# All variables below fall back to sensible defaults if .env is absent.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

# ---------------------------------------------------------------------------
# Configuration (values come from .env; defaults shown as fallbacks)
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="${S3_BUCKET:-stockpulse-data-us}"
S3_SCRIPTS_BUCKET="${S3_SCRIPTS_BUCKET:-stockpulse-scripts-us}"
KINESIS_STREAM="${KINESIS_STREAM:-stockpulse-stream}"
DLQ_NAME="${DLQ_NAME:-stockpulse-dlq}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-stockpulse-alerts}"
GLUE_DB="${GLUE_DB:-stockpulse_db}"
LAMBDA_INGESTER_NAME="${LAMBDA_INGESTER_NAME:-stockpulse-ingester}"
LAMBDA_PROCESSOR_NAME="${LAMBDA_PROCESSOR_NAME:-stockpulse-processor}"
GLUE_JOB_NAME="${GLUE_JOB_NAME:-stockpulse-ohlcv-transform}"

echo "============================================================"
echo "StockPulse — AWS Infrastructure Setup"
echo "Region:  $AWS_REGION"
echo "Account: $ACCOUNT_ID"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. S3 Buckets
# ---------------------------------------------------------------------------
echo ""
echo "[1/9] Creating S3 buckets..."

for bucket in "$S3_BUCKET" "$S3_SCRIPTS_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "  Bucket s3://$bucket already exists — skipping"
  else
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION"
    else
      aws s3api create-bucket \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    echo "  Created s3://$bucket"
  fi
done

# Versioning
aws s3api put-bucket-versioning \
  --bucket "$S3_BUCKET" \
  --versioning-configuration Status=Enabled

# SSE-S3 encryption
aws s3api put-bucket-encryption \
  --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block all public access
aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Lifecycle rules: raw/ → GLACIER_IR after 7 days, archive/ → delete after 30 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$S3_BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "archive-raw",
        "Filter": { "Prefix": "raw/" },
        "Status": "Enabled",
        "Transitions": [
          { "Days": 7, "StorageClass": "GLACIER_IR" }
        ]
      },
      {
        "ID": "delete-archive",
        "Filter": { "Prefix": "archive/" },
        "Status": "Enabled",
        "Expiration": { "Days": 30 }
      },
      {
        "ID": "expire-athena-results",
        "Filter": { "Prefix": "athena-results/" },
        "Status": "Enabled",
        "Expiration": { "Days": 7 }
      }
    ]
  }'

echo "  S3 configuration complete."

# ---------------------------------------------------------------------------
# 2. IAM Roles
# ---------------------------------------------------------------------------
echo ""
echo "[2/9] Creating IAM roles..."

LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
GLUE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
REDSHIFT_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"redshift.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
EVENTBRIDGE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

create_role_if_not_exists() {
  local role_name="$1"
  local trust_doc="$2"
  if aws iam get-role --role-name "$role_name" 2>/dev/null; then
    echo "  Role $role_name already exists — skipping"
  else
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_doc" \
      --description "StockPulse: $role_name"
    echo "  Created role: $role_name"
  fi
}

create_role_if_not_exists "stockpulse-ingester-role"   "$LAMBDA_TRUST"
create_role_if_not_exists "stockpulse-processor-role"  "$LAMBDA_TRUST"
create_role_if_not_exists "stockpulse-glue-role"       "$GLUE_TRUST"
create_role_if_not_exists "stockpulse-redshift-role"   "$REDSHIFT_TRUST"
create_role_if_not_exists "stockpulse-eventbridge-role" "$EVENTBRIDGE_TRUST"

# Attach managed policies
aws iam attach-role-policy --role-name stockpulse-ingester-role  \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name stockpulse-processor-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name stockpulse-glue-role      \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

# Inline policy: Ingester → Kinesis PutRecords
aws iam put-role-policy \
  --role-name stockpulse-ingester-role \
  --policy-name KinesisWritePolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"kinesis:PutRecord\", \"kinesis:PutRecords\", \"kinesis:DescribeStream\"],
      \"Resource\": \"arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID:stream/$KINESIS_STREAM\"
    }]
  }"

# Inline policy: Processor → S3 write + SQS DLQ
aws iam put-role-policy \
  --role-name stockpulse-processor-role \
  --policy-name S3WritePolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:PutObject\", \"s3:GetObject\", \"s3:ListBucket\"],
        \"Resource\": [
          \"arn:aws:s3:::$S3_BUCKET\",
          \"arn:aws:s3:::$S3_BUCKET/*\"
        ]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"kinesis:GetRecords\", \"kinesis:GetShardIterator\",
                    \"kinesis:DescribeStream\", \"kinesis:ListShards\",
                    \"kinesis:ListStreams\"],
        \"Resource\": \"arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID:stream/$KINESIS_STREAM\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"sqs:SendMessage\"],
        \"Resource\": \"arn:aws:sqs:$AWS_REGION:$ACCOUNT_ID:$DLQ_NAME\"
      }
    ]
  }"

# Inline policy: Glue → S3 read/write
aws iam put-role-policy \
  --role-name stockpulse-glue-role \
  --policy-name S3ReadWritePolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\", \"s3:ListBucket\"],
      \"Resource\": [
        \"arn:aws:s3:::$S3_BUCKET\",
        \"arn:aws:s3:::$S3_BUCKET/*\",
        \"arn:aws:s3:::$S3_SCRIPTS_BUCKET\",
        \"arn:aws:s3:::$S3_SCRIPTS_BUCKET/*\"
      ]
    }]
  }"

# Inline policy: Redshift → S3 read for COPY
aws iam put-role-policy \
  --role-name stockpulse-redshift-role \
  --policy-name S3ReadPolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
      \"Resource\": [
        \"arn:aws:s3:::$S3_BUCKET\",
        \"arn:aws:s3:::$S3_BUCKET/*\"
      ]
    }]
  }"

# Inline policy: EventBridge → invoke Lambda
aws iam put-role-policy \
  --role-name stockpulse-eventbridge-role \
  --policy-name LambdaInvokePolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"lambda:InvokeFunction\",
      \"Resource\": \"arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_INGESTER_NAME\"
    }]
  }"

echo "  IAM roles and policies configured."

# ---------------------------------------------------------------------------
# 3. Kinesis Data Stream
# ---------------------------------------------------------------------------
echo ""
echo "[3/9] Creating Kinesis Data Stream..."

if aws kinesis describe-stream-summary \
    --stream-name "$KINESIS_STREAM" \
    --region "$AWS_REGION" 2>/dev/null; then
  echo "  Stream $KINESIS_STREAM already exists — skipping"
else
  aws kinesis create-stream \
    --stream-name "$KINESIS_STREAM" \
    --shard-count 1 \
    --region "$AWS_REGION"

  # Wait for stream to be ACTIVE
  echo "  Waiting for stream to become ACTIVE..."
  aws kinesis wait stream-exists --stream-name "$KINESIS_STREAM" --region "$AWS_REGION"

  # Enable server-side encryption
  aws kinesis start-stream-encryption \
    --stream-name "$KINESIS_STREAM" \
    --encryption-type KMS \
    --key-id alias/aws/kinesis \
    --region "$AWS_REGION"

  echo "  Kinesis stream '$KINESIS_STREAM' created (1 shard, 24h retention, SSE enabled)."
fi

# Set retention to 24 hours (default is already 24h, but be explicit)
aws kinesis increase-stream-retention-period \
  --stream-name "$KINESIS_STREAM" \
  --retention-period-hours 24 \
  --region "$AWS_REGION" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. SQS Dead Letter Queue
# ---------------------------------------------------------------------------
echo ""
echo "[4/9] Creating SQS Dead Letter Queue..."

DLQ_URL=$(aws sqs create-queue \
  --queue-name "$DLQ_NAME" \
  --attributes MessageRetentionPeriod=1209600 \
  --region "$AWS_REGION" \
  --query QueueUrl \
  --output text 2>/dev/null || \
  aws sqs get-queue-url \
    --queue-name "$DLQ_NAME" \
    --region "$AWS_REGION" \
    --query QueueUrl \
    --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query Attributes.QueueArn \
  --output text \
  --region "$AWS_REGION")

echo "  SQS DLQ created: $DLQ_ARN"

# ---------------------------------------------------------------------------
# 5. SNS Topic for CloudWatch Alarms
# ---------------------------------------------------------------------------
echo ""
echo "[5/9] Creating SNS topic for alerts..."

SNS_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --region "$AWS_REGION" \
  --query TopicArn \
  --output text)

echo "  SNS topic: $SNS_ARN"
echo "  NOTE: Subscribe your email manually:"
echo "    aws sns subscribe --topic-arn $SNS_ARN --protocol email --notification-endpoint you@example.com"

# ---------------------------------------------------------------------------
# 6. CloudWatch Alarms
# ---------------------------------------------------------------------------
echo ""
echo "[6/9] Creating CloudWatch alarms..."

# Alarm 1: Lambda Ingester errors
aws cloudwatch put-metric-alarm \
  --alarm-name "StockPulse-Ingester-Errors" \
  --alarm-description "Lambda ingester has errors — check Polygon.io API key or Kinesis permissions" \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value="$LAMBDA_INGESTER_NAME" \
  --statistic Sum \
  --period 60 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --evaluation-periods 1 \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching \
  --region "$AWS_REGION"

# Alarm 2: Lambda Processor errors
aws cloudwatch put-metric-alarm \
  --alarm-name "StockPulse-Processor-Errors" \
  --alarm-description "Lambda processor has errors — check S3 permissions or PyArrow layer" \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value="$LAMBDA_PROCESSOR_NAME" \
  --statistic Sum \
  --period 60 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --evaluation-periods 1 \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching \
  --region "$AWS_REGION"

# Alarm 3: Kinesis iterator age > 60s (consumer falling behind)
aws cloudwatch put-metric-alarm \
  --alarm-name "StockPulse-Kinesis-IteratorAge" \
  --alarm-description "Kinesis consumer is falling behind — processor Lambda may be slow or throttled" \
  --namespace AWS/Kinesis \
  --metric-name GetRecords.IteratorAgeMilliseconds \
  --dimensions Name=StreamName,Value="$KINESIS_STREAM" \
  --statistic Maximum \
  --period 60 \
  --threshold 60000 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching \
  --region "$AWS_REGION"

# Alarm 4: Lambda Ingester throttles
aws cloudwatch put-metric-alarm \
  --alarm-name "StockPulse-Ingester-Throttles" \
  --alarm-description "Lambda ingester is being throttled — check concurrency limits" \
  --namespace AWS/Lambda \
  --metric-name Throttles \
  --dimensions Name=FunctionName,Value="$LAMBDA_INGESTER_NAME" \
  --statistic Sum \
  --period 60 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --evaluation-periods 1 \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching \
  --region "$AWS_REGION"

# Alarm 5: DLQ has messages (failed records)
aws cloudwatch put-metric-alarm \
  --alarm-name "StockPulse-DLQ-MessageCount" \
  --alarm-description "Records failed to process and are in the DLQ — manual investigation needed" \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value="$DLQ_NAME" \
  --statistic Sum \
  --period 300 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --evaluation-periods 1 \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching \
  --region "$AWS_REGION"

echo "  5 CloudWatch alarms created."

# ---------------------------------------------------------------------------
# 7. Glue Database
# ---------------------------------------------------------------------------
echo ""
echo "[7/9] Creating Glue Data Catalog database..."

aws glue create-database \
  --database-input Name="$GLUE_DB",Description="StockPulse processed OHLCV data" \
  --region "$AWS_REGION" 2>/dev/null || echo "  Glue database '$GLUE_DB' already exists — skipping"

echo "  Glue database: $GLUE_DB"

# ---------------------------------------------------------------------------
# 8. EventBridge Scheduler Rule (market hours: Mon-Fri, 9:30 AM - 4:00 PM ET)
# ---------------------------------------------------------------------------
echo ""
echo "[8/9] Creating EventBridge rule (will be activated after Lambda is deployed)..."

# Note: This rule is created DISABLED — enable after deploying Lambda ingester
aws events put-rule \
  --name "stockpulse-ingester-schedule" \
  --schedule-expression "cron(*/1 14-20 ? * MON-FRI *)" \
  --description "Triggers StockPulse ingester every minute during market hours (Mon-Fri 9:30-4:00 ET / 14:30-21:00 UTC)" \
  --state DISABLED \
  --region "$AWS_REGION" 2>/dev/null || echo "  EventBridge rule already exists — skipping"

echo "  EventBridge rule created (DISABLED — enable after Lambda deployment)."
echo "  To enable: aws events enable-rule --name stockpulse-ingester-schedule --region $AWS_REGION"

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "Setup complete! Next steps:"
echo ""
echo "1. Deploy Lambda functions:"
echo "   POLYGON_API_KEY=<your-key> ./scripts/deploy_lambda.sh"
echo ""
echo "2. Upload Glue script:"
echo "   ./scripts/upload_glue_script.sh"
echo ""
echo "3. Subscribe to SNS alerts:"
echo "   aws sns subscribe --topic-arn $SNS_ARN \\"
echo "     --protocol email --notification-endpoint you@example.com"
echo ""
echo "4. Provision Redshift Serverless via AWS Console:"
echo "   Namespace: stockpulse-ns | Workgroup: stockpulse-wg | Base capacity: 8 RPUs"
echo "   Then run: sql/redshift_ddl.sql"
echo ""
echo "5. Sign up for Grafana Cloud (free) and import grafana/dashboard.json"
echo ""
echo "   S3 Bucket:      s3://$S3_BUCKET"
echo "   Kinesis Stream: $KINESIS_STREAM"
echo "   DLQ ARN:        $DLQ_ARN"
echo "   SNS Topic:      $SNS_ARN"
echo "   Glue DB:        $GLUE_DB"
echo "   Region:         $AWS_REGION"
echo "   Account ID:     $ACCOUNT_ID"
echo "============================================================"
