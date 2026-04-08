"""
StockPulse — Central configuration.

All values are read from environment variables so that nothing is hardcoded.
Locally, populate these via .env (gitignored). In AWS, they are set as
Lambda environment variables or shell exports by the deploy/setup scripts.

Usage:
    from config import settings
    print(settings.S3_BUCKET)
"""

import os
from pathlib import Path

# Load .env automatically in local/test environments.
# python-dotenv is not required in AWS Lambda — env vars are injected by AWS.
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent.parent / ".env")
except ImportError:
    pass

# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
S3_BUCKET = os.environ.get("S3_BUCKET", "stockpulse-data-us")
S3_SCRIPTS_BUCKET = os.environ.get("S3_SCRIPTS_BUCKET", "stockpulse-scripts-us")

# ---------------------------------------------------------------------------
# Kinesis
# ---------------------------------------------------------------------------
KINESIS_STREAM = os.environ.get("KINESIS_STREAM", "stockpulse-stream")

# ---------------------------------------------------------------------------
# SQS / SNS
# ---------------------------------------------------------------------------
DLQ_NAME = os.environ.get("DLQ_NAME", "stockpulse-dlq")
SNS_TOPIC_NAME = os.environ.get("SNS_TOPIC_NAME", "stockpulse-alerts")

# ---------------------------------------------------------------------------
# Glue
# ---------------------------------------------------------------------------
GLUE_DB = os.environ.get("GLUE_DB", "stockpulse_db")
GLUE_JOB_NAME = os.environ.get("GLUE_JOB_NAME", "stockpulse-ohlcv-transform")

# ---------------------------------------------------------------------------
# Lambda function names
# ---------------------------------------------------------------------------
LAMBDA_INGESTER_NAME = os.environ.get("LAMBDA_INGESTER_NAME", "stockpulse-ingester")
LAMBDA_PROCESSOR_NAME = os.environ.get("LAMBDA_PROCESSOR_NAME", "stockpulse-processor")

# ---------------------------------------------------------------------------
# Polygon.io
# The actual API key lives in AWS Secrets Manager, not here.
# POLYGON_SECRET_NAME is the only value needed — the Lambda fetches the key
# at runtime. For local CLI use, you may still export POLYGON_API_KEY directly.
# ---------------------------------------------------------------------------
POLYGON_SECRET_NAME = os.environ.get("POLYGON_SECRET_NAME", "stockpulse/polygon-api-key")

# ---------------------------------------------------------------------------
# Symbols
# ---------------------------------------------------------------------------
SYMBOLS = os.environ.get(
    "SYMBOLS", "AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ"
).split(",")
