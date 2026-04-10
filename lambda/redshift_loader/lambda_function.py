"""
StockPulse — Redshift Loader Lambda
Triggered by EventBridge when the Glue job (stockpulse-ohlcv-transform) succeeds.
Uses Redshift Data API to execute the COPY command — no VPC or direct DB connection needed.

Trigger:     EventBridge rule on Glue job state SUCCEEDED
Destination: Redshift Serverless (stockpulse-wg / dev / public.ohlcv)
"""

import json
import os
import time

import boto3

WORKGROUP_NAME = os.environ.get("REDSHIFT_WORKGROUP", "stockpulse-wg")
DATABASE       = os.environ.get("REDSHIFT_DATABASE", "dev")
DB_USER        = os.environ.get("REDSHIFT_DB_USER", "admin")
S3_PATH        = os.environ.get("S3_PROCESSED_PATH", "s3://stockpulse-data-us2/processed/")
IAM_ROLE       = os.environ.get("REDSHIFT_IAM_ROLE", "arn:aws:iam::985823270443:role/stockpulse-redshift-role")

TRUNCATE_AND_COPY_SQL = f"""
TRUNCATE TABLE public.ohlcv;

COPY public.ohlcv (
    symbol,
    "open",
    high,
    low,
    "close",
    volume,
    vwap,
    timestamp_ms,
    num_trades,
    event_time,
    trade_date,
    price_change,
    price_change_pct,
    bar_range_pct,
    is_market_hours,
    avg_volume_10bar,
    ingestion_time
)
FROM '{S3_PATH}'
IAM_ROLE '{IAM_ROLE}'
FORMAT AS PARQUET
SERIALIZETOJSON;
"""

redshift_data = boto3.client("redshift-data")


def lambda_handler(event, context):
    print(f"Triggering Redshift TRUNCATE + COPY from {S3_PATH}")
    print(f"Glue event: {json.dumps(event)}")

    # Execute TRUNCATE + COPY as a single transaction via Redshift Data API
    response = redshift_data.execute_statement(
        WorkgroupName=WORKGROUP_NAME,
        Database=DATABASE,
        Sql=TRUNCATE_AND_COPY_SQL,
    )

    statement_id = response["Id"]
    print(f"COPY statement submitted. ID: {statement_id}")

    # Poll until complete (max 5 min)
    for _ in range(30):
        time.sleep(10)
        status = redshift_data.describe_statement(Id=statement_id)
        state = status["Status"]
        print(f"COPY status: {state}")

        if state == "FINISHED":
            print("COPY completed successfully.")
            return {"statusCode": 200, "body": "COPY succeeded", "statementId": statement_id}

        if state in ("FAILED", "ABORTED"):
            error = status.get("Error", "unknown error")
            print(f"COPY failed: {error}")
            raise RuntimeError(f"Redshift COPY failed: {error}")

    raise TimeoutError("Redshift COPY did not complete within 5 minutes.")
