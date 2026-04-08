"""
StockPulse — Lambda Processor
Consumes records from Kinesis Data Streams, converts them to Parquet,
and writes to S3 raw zone with Hive-style partitioning.

Trigger:     Amazon Kinesis Data Stream (batch size: 100, LATEST)
Destination: Amazon S3 s3://stockpulse-data/raw/year=YYYY/month=MM/day=DD/
Failure:     SQS Dead Letter Queue (stockpulse-dlq) via OnFailure destination

Lambda Layer required: PyArrow (built for Amazon Linux 2)
  docker run -v $(pwd):/output amazonlinux:2 bash -c \
    "yum install -y python3-pip && pip3 install pyarrow -t /output/python/"
"""

import base64
import json
import os
from datetime import datetime, timezone
from io import BytesIO

import boto3
import pyarrow as pa
import pyarrow.parquet as pq

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
S3_BUCKET = os.environ.get("S3_BUCKET", "stockpulse-data")
S3_PREFIX = "raw"

# ---------------------------------------------------------------------------
# PyArrow schema — must match ingester record structure exactly
# ---------------------------------------------------------------------------
SCHEMA = pa.schema(
    [
        ("symbol", pa.string()),
        ("open", pa.float64()),
        ("high", pa.float64()),
        ("low", pa.float64()),
        ("close", pa.float64()),
        ("volume", pa.float64()),   # float64 to handle None gracefully
        ("vwap", pa.float64()),
        ("timestamp", pa.int64()),
        ("num_trades", pa.float64()),  # float64 to handle None gracefully
        ("ingestion_time", pa.int64()),
    ]
)

# ---------------------------------------------------------------------------
# AWS clients
# ---------------------------------------------------------------------------
s3_client = boto3.client("s3")


def _decode_kinesis_record(record: dict) -> dict | None:
    """Decode a single Kinesis record from base64 JSON."""
    try:
        raw = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
        return json.loads(raw)
    except Exception as e:
        print(f"Failed to decode record: {e} — seq={record.get('kinesis', {}).get('sequenceNumber')}")
        return None


def _build_arrow_table(payloads: list[dict]) -> pa.Table:
    """Convert a list of payload dicts to a typed PyArrow table."""
    columns = {field.name: [] for field in SCHEMA}
    for payload in payloads:
        for field in SCHEMA:
            columns[field.name].append(payload.get(field.name))
    return pa.table(columns, schema=SCHEMA)


def _s3_key(now: datetime, request_id: str) -> str:
    """
    Build an S3 key with Hive-style partitioning for Athena compatibility.
    Pattern: raw/year=YYYY/month=MM/day=DD/batch_HHMMSS_<request_id>.parquet
    """
    return (
        f"{S3_PREFIX}/"
        f"year={now.year}/"
        f"month={now.month:02d}/"
        f"day={now.day:02d}/"
        f"batch_{now.strftime('%H%M%S')}_{request_id[:8]}.parquet"
    )


def _write_parquet_to_s3(table: pa.Table, key: str) -> None:
    """Serialise PyArrow table to Snappy-compressed Parquet and upload to S3."""
    buffer = BytesIO()
    pq.write_table(table, buffer, compression="snappy")
    buffer.seek(0)
    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=buffer.getvalue(),
        ContentType="application/octet-stream",
    )


def lambda_handler(event, context):
    """
    Main handler — invoked by Kinesis event source mapping.
    Processes a batch of up to 100 Kinesis records per invocation.
    """
    kinesis_records = event.get("Records", [])
    print(f"Received {len(kinesis_records)} Kinesis records")

    payloads = []
    decode_failures = 0

    for record in kinesis_records:
        payload = _decode_kinesis_record(record)
        if payload is not None:
            payloads.append(payload)
        else:
            decode_failures += 1

    if not payloads:
        print(f"No valid payloads ({decode_failures} decode failures). Nothing to write.")
        return {"statusCode": 200, "body": "no valid records"}

    try:
        table = _build_arrow_table(payloads)
        now = datetime.now(timezone.utc)
        key = _s3_key(now, context.aws_request_id)
        _write_parquet_to_s3(table, key)
        print(
            f"Wrote {table.num_rows} rows → s3://{S3_BUCKET}/{key} "
            f"(decode_failures={decode_failures})"
        )
    except Exception as e:
        # Raise so Lambda retries the batch and eventually routes to DLQ
        print(f"Fatal error writing Parquet to S3: {e}")
        raise

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "received": len(kinesis_records),
                "written": table.num_rows,
                "decode_failures": decode_failures,
                "s3_key": key,
            }
        ),
    }
