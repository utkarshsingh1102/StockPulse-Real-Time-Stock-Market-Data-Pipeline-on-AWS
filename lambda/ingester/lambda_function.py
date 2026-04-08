"""
StockPulse — Lambda Ingester
Fetches stock data from Polygon.io and publishes to Kinesis Data Streams.

Uses the Snapshot endpoint to fetch all 10 symbols in a single API call,
respecting Polygon.io free tier rate limit of 5 requests/minute.

Triggered by: Amazon EventBridge (cron: every 1 min, market hours)
Destination:  Amazon Kinesis Data Streams (stockpulse-stream)
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
SNAPSHOT_URL = (
    f"{BASE_URL}/v2/snapshot/locale/us/markets/stocks/tickers"
    f"?tickers={','.join(SYMBOLS)}&apiKey={POLYGON_API_KEY}"
)


def _fetch_snapshot() -> list[dict]:
    """
    Fetch a market snapshot for all tracked symbols in a single API call.
    Falls back to per-symbol /prev endpoint if snapshot returns no data.
    Returns a list of normalised tick records.
    """
    records = []
    ingestion_ts = int(time.time() * 1000)

    try:
        response = http.request("GET", SNAPSHOT_URL)
        if response.status == 429:
            print("Rate limited by Polygon.io — backing off 15s")
            time.sleep(15)
            response = http.request("GET", SNAPSHOT_URL)

        data = json.loads(response.data.decode("utf-8"))

        tickers = data.get("tickers") or []
        for ticker in tickers:
            symbol = ticker.get("ticker")
            day = ticker.get("day") or {}
            prev_day = ticker.get("prevDay") or {}

            # Prefer current day bar; fall back to prevDay
            bar = day if day.get("c") else prev_day
            if not bar.get("c"):
                print(f"No bar data for {symbol} — skipping")
                continue

            records.append(
                {
                    "symbol": symbol,
                    "open": bar.get("o"),
                    "high": bar.get("h"),
                    "low": bar.get("l"),
                    "close": bar.get("c"),
                    "volume": bar.get("v"),
                    "vwap": bar.get("vw"),
                    "timestamp": ticker.get("lastTrade", {}).get("t")
                    or int(time.time() * 1000),
                    "num_trades": bar.get("n"),
                    "ingestion_time": ingestion_ts,
                }
            )

    except Exception as e:
        print(f"Snapshot fetch failed: {e} — falling back to per-symbol /prev")
        records = _fetch_prev_close(ingestion_ts)

    return records


def _fetch_prev_close(ingestion_ts: int) -> list[dict]:
    """
    Fallback: fetch previous close for each symbol individually.
    Respects rate limit with a 13s delay between calls (5 req/min = 12s gap).
    """
    records = []
    for i, symbol in enumerate(SYMBOLS):
        if i > 0:
            time.sleep(13)  # Stay safely under 5 req/min
        try:
            url = (
                f"{BASE_URL}/v2/aggs/ticker/{symbol}/prev"
                f"?adjusted=true&apiKey={POLYGON_API_KEY}"
            )
            response = http.request("GET", url)
            data = json.loads(response.data.decode("utf-8"))

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
        except Exception as e:
            print(f"Error fetching {symbol}: {e}")

    return records


def _put_to_kinesis(records: list[dict]) -> int:
    """
    Batch-put records to Kinesis. Returns count of failed records.
    Kinesis put_records limit: 500 records or 5 MB per call.
    """
    if not records:
        return 0

    kinesis_records = [
        {
            "Data": json.dumps(record).encode("utf-8"),
            "PartitionKey": record["symbol"],  # Same-symbol events → same shard
        }
        for record in records[:500]
    ]

    failed = 0
    try:
        response = kinesis_client.put_records(
            StreamName=KINESIS_STREAM_NAME, Records=kinesis_records
        )
        failed = response.get("FailedRecordCount", 0)

        # Retry failed records once with exponential backoff
        if failed > 0:
            print(f"{failed} records failed — retrying after 2s")
            time.sleep(2)
            failed_indices = [
                i
                for i, r in enumerate(response["Records"])
                if r.get("ErrorCode")
            ]
            retry_records = [kinesis_records[i] for i in failed_indices]
            retry_response = kinesis_client.put_records(
                StreamName=KINESIS_STREAM_NAME, Records=retry_records
            )
            failed = retry_response.get("FailedRecordCount", 0)

    except Exception as e:
        print(f"Kinesis put_records error: {e}")
        failed = len(kinesis_records)

    return failed


def lambda_handler(event, context):
    """Main Lambda handler — invoked by EventBridge every 1 minute."""
    print(f"StockPulse ingester started. Tracking: {SYMBOLS}")

    records = _fetch_snapshot()
    print(f"Fetched {len(records)} records from Polygon.io")

    failed = _put_to_kinesis(records)
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
