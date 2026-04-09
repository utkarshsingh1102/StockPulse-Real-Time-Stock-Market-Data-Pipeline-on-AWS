"""
StockPulse — Lambda Ingester
Fetches previous-day OHLCV data from Polygon.io (free tier) and publishes
to Kinesis Data Stream for processing.

Uses /v2/aggs/ticker/{symbol}/prev — available on Polygon.io free tier.
Rate limit: 5 req/min → 13s delay between calls.
10 symbols × 13s = ~130s → Lambda timeout must be ≥ 180s.

Triggered by: Amazon EventBridge (cron: every 5 min, market hours)
Destination:  Amazon Kinesis Data Stream (stockpulse-stream)
"""

import json
import os
import time
import boto3
import urllib3

# ---------------------------------------------------------------------------
# Configuration (all values come from Lambda environment variables)
# ---------------------------------------------------------------------------
KINESIS_STREAM_NAME = os.environ.get("KINESIS_STREAM_NAME", "stockpulse-stream")
SYMBOLS = os.environ.get(
    "SYMBOLS", "AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ"
).split(",")
POLYGON_SECRET_NAME = os.environ.get("POLYGON_SECRET_NAME", "stockpulse/polygon-api-key")

BASE_URL = "https://api.polygon.io"

# ---------------------------------------------------------------------------
# AWS clients (initialised once outside handler for connection reuse)
# ---------------------------------------------------------------------------
kinesis_client = boto3.client("kinesis")
secrets_client = boto3.client("secretsmanager")
http = urllib3.PoolManager(timeout=urllib3.Timeout(connect=5.0, read=10.0))


def _get_polygon_api_key() -> str:
    """Fetch the Polygon.io API key from AWS Secrets Manager at cold-start."""
    secret = secrets_client.get_secret_value(SecretId=POLYGON_SECRET_NAME)
    return json.loads(secret["SecretString"])["POLYGON_API_KEY"]


# Fetched once per Lambda container lifetime (cached across warm invocations)
POLYGON_API_KEY = _get_polygon_api_key()


def _fetch_all_symbols() -> list[dict]:
    """
    Fetch previous-day OHLCV for each symbol using /v2/aggs/ticker/{symbol}/prev.
    Free tier supports this endpoint. Rate limit: 5 req/min → 13s between calls.
    """
    records = []
    ingestion_ts = int(time.time() * 1000)

    for i, symbol in enumerate(SYMBOLS):
        if i > 0:
            time.sleep(13)  # Stay safely under 5 req/min (12s minimum gap)
        try:
            url = (
                f"{BASE_URL}/v2/aggs/ticker/{symbol}/prev"
                f"?adjusted=true&apiKey={POLYGON_API_KEY}"
            )
            response = http.request("GET", url)

            if response.status == 429:
                print(f"Rate limited on {symbol} — backing off 30s")
                time.sleep(30)
                response = http.request("GET", url)

            data = json.loads(response.data.decode("utf-8"))

            if data.get("status") == "NOT_AUTHORIZED":
                print(f"NOT_AUTHORIZED for {symbol}: {data.get('message')}")
                continue

            if data.get("resultsCount", 0) > 0:
                for result in data["results"]:
                    records.append(
                        {
                            "symbol": symbol,
                            "open": result.get("o"),
                            "high": result.get("h"),
                            "low": result.get("l"),
                            "close": result.get("c"),
                            "volume": result.get("v"),
                            "vwap": result.get("vw"),
                            "timestamp": result.get("t"),
                            "num_trades": result.get("n"),
                            "ingestion_time": ingestion_ts,
                        }
                    )
                print(f"  {symbol}: fetched {data['resultsCount']} record(s)")
            else:
                print(f"  {symbol}: no results (status={data.get('status')})")

        except Exception as e:
            print(f"Error fetching {symbol}: {e}")

    return records


def _send_to_kinesis(records: list[dict]) -> int:
    """
    Batch-send records to Kinesis. Returns count of failed records.
    Kinesis put_records limit: 500 records or 5MB per call.
    Each record is partitioned by symbol for ordered processing per ticker.
    """
    if not records:
        return 0

    failed = 0
    # Kinesis allows up to 500 records per put_records call
    for i in range(0, len(records), 500):
        batch = records[i : i + 500]
        kinesis_records = [
            {
                "Data": json.dumps(record).encode("utf-8"),
                "PartitionKey": record["symbol"],
            }
            for record in batch
        ]
        try:
            response = kinesis_client.put_records(
                StreamName=KINESIS_STREAM_NAME,
                Records=kinesis_records,
            )
            batch_failed = response.get("FailedRecordCount", 0)
            if batch_failed > 0:
                for j, rec in enumerate(response["Records"]):
                    if "ErrorCode" in rec:
                        print(f"Kinesis put failed record {j}: {rec.get('ErrorMessage')}")
            failed += batch_failed
        except Exception as e:
            print(f"Kinesis put_records error: {e}")
            failed += len(batch)

    return failed


def lambda_handler(event, context):
    """Main Lambda handler — invoked by EventBridge every 5 minutes."""
    print(f"StockPulse ingester started. Tracking: {SYMBOLS}")

    records = _fetch_all_symbols()
    print(f"Fetched {len(records)} records from Polygon.io")

    failed = _send_to_kinesis(records)
    success = len(records) - failed

    print(f"Kinesis result: {success} succeeded, {failed} failed")

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "fetched": len(records),
                "published": success,
                "failed": failed,
            }
        ),
    }
