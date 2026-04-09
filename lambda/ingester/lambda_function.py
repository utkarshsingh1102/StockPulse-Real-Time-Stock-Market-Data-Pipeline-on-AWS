"""
StockPulse — Lambda Ingester
Fetches previous-day OHLCV data from Polygon.io (free tier) and publishes
to SQS for processing.

Uses /v2/aggs/ticker/{symbol}/prev — available on Polygon.io free tier.
Rate limit: 5 req/min → 13s delay between calls.
10 symbols × 13s = ~130s → Lambda timeout must be ≥ 180s.

Triggered by: Amazon EventBridge (cron: every 1 min, market hours)
Destination:  Amazon SQS (stockpulse-queue)
"""

import json
import os
import time
import boto3
import urllib3

# ---------------------------------------------------------------------------
# Configuration (all values come from Lambda environment variables)
# ---------------------------------------------------------------------------
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
SYMBOLS = os.environ.get(
    "SYMBOLS", "AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ"
).split(",")
POLYGON_SECRET_NAME = os.environ.get("POLYGON_SECRET_NAME", "stockpulse/polygon-api-key")

BASE_URL = "https://api.polygon.io"

# ---------------------------------------------------------------------------
# AWS clients (initialised once outside handler for connection reuse)
# ---------------------------------------------------------------------------
sqs_client = boto3.client("sqs")
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


def _send_to_sqs(records: list[dict]) -> int:
    """
    Batch-send records to SQS. Returns count of failed records.
    SQS send_message_batch limit: 10 messages per call.
    """
    if not records:
        return 0

    failed = 0
    # SQS batch limit is 10 messages per call
    for i in range(0, len(records), 10):
        batch = records[i : i + 10]
        entries = [
            {"Id": str(j), "MessageBody": json.dumps(record)}
            for j, record in enumerate(batch)
        ]
        try:
            response = sqs_client.send_message_batch(
                QueueUrl=SQS_QUEUE_URL,
                Entries=entries,
            )
            batch_failed = len(response.get("Failed", []))
            if batch_failed > 0:
                for f in response["Failed"]:
                    print(f"SQS send failed Id={f['Id']}: {f.get('Message')}")
            failed += batch_failed
        except Exception as e:
            print(f"SQS send_message_batch error: {e}")
            failed += len(batch)

    return failed


def lambda_handler(event, context):
    """Main Lambda handler — invoked by EventBridge every 1 minute."""
    print(f"StockPulse ingester started. Tracking: {SYMBOLS}")

    records = _fetch_all_symbols()
    print(f"Fetched {len(records)} records from Polygon.io")

    failed = _send_to_sqs(records)
    success = len(records) - failed

    print(f"SQS result: {success} succeeded, {failed} failed")

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
