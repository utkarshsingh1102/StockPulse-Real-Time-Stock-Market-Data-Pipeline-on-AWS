"""
Tests for lambda/ingester/lambda_function.py
Run: pytest tests/test_ingester.py -v
"""

import base64
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub out AWS SDK before importing the Lambda module
# ---------------------------------------------------------------------------
boto3_mock = MagicMock()
sys.modules["boto3"] = boto3_mock

# Set required env vars
os.environ.setdefault("POLYGON_API_KEY", "test-api-key")
os.environ.setdefault("KINESIS_STREAM_NAME", "stockpulse-stream")
os.environ.setdefault("SYMBOLS", "AAPL,MSFT,GOOGL")

# Import after env/mocks are set
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "ingester"))
import lambda_function  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _mock_snapshot_response(tickers: list[dict]) -> MagicMock:
    response = MagicMock()
    response.status = 200
    response.data = json.dumps({"tickers": tickers, "status": "OK"}).encode("utf-8")
    return response


MOCK_TICKER = {
    "ticker": "AAPL",
    "day": {"o": 150.0, "h": 155.0, "l": 148.0, "c": 153.5, "v": 1000000, "vw": 152.0, "n": 5000},
    "prevDay": {},
    "lastTrade": {"t": 1700000000000},
}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class TestFetchSnapshot(unittest.TestCase):

    @patch.object(lambda_function, "http")
    def test_fetch_snapshot_parses_ticker(self, mock_http):
        mock_http.request.return_value = _mock_snapshot_response([MOCK_TICKER])

        records = lambda_function._fetch_snapshot()

        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["symbol"], "AAPL")
        self.assertEqual(r["open"], 150.0)
        self.assertEqual(r["close"], 153.5)
        self.assertEqual(r["volume"], 1000000)
        self.assertIn("ingestion_time", r)

    @patch.object(lambda_function, "http")
    def test_fetch_snapshot_skips_empty_bar(self, mock_http):
        ticker_no_bar = {"ticker": "MSFT", "day": {}, "prevDay": {}, "lastTrade": {"t": 0}}
        mock_http.request.return_value = _mock_snapshot_response([MOCK_TICKER, ticker_no_bar])

        records = lambda_function._fetch_snapshot()

        # MSFT should be skipped; only AAPL returned
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["symbol"], "AAPL")

    @patch.object(lambda_function, "http")
    def test_fetch_snapshot_falls_back_on_exception(self, mock_http):
        mock_http.request.side_effect = Exception("Network error")

        with patch.object(lambda_function, "_fetch_prev_close", return_value=[]) as mock_fallback:
            lambda_function._fetch_snapshot()
            mock_fallback.assert_called_once()

    @patch.object(lambda_function, "http")
    def test_rate_limit_retries(self, mock_http):
        rate_limited = MagicMock()
        rate_limited.status = 429
        rate_limited.data = json.dumps({}).encode("utf-8")

        ok_response = _mock_snapshot_response([MOCK_TICKER])
        mock_http.request.side_effect = [rate_limited, ok_response]

        with patch("lambda_function.time.sleep"):
            records = lambda_function._fetch_snapshot()

        self.assertEqual(mock_http.request.call_count, 2)
        self.assertEqual(len(records), 1)


class TestPutToKinesis(unittest.TestCase):

    def setUp(self):
        lambda_function.kinesis_client = MagicMock()

    def test_empty_records_returns_zero(self):
        failed = lambda_function._put_to_kinesis([])
        self.assertEqual(failed, 0)
        lambda_function.kinesis_client.put_records.assert_not_called()

    def test_successful_put(self):
        lambda_function.kinesis_client.put_records.return_value = {
            "FailedRecordCount": 0,
            "Records": [{"SequenceNumber": "1", "ShardId": "0"}],
        }
        records = [{"symbol": "AAPL", "open": 1.0, "high": 2.0, "low": 0.5,
                    "close": 1.5, "volume": 100, "vwap": 1.2,
                    "timestamp": 1000, "num_trades": 50, "ingestion_time": 2000}]

        failed = lambda_function._put_to_kinesis(records)

        self.assertEqual(failed, 0)
        call_args = lambda_function.kinesis_client.put_records.call_args
        kinesis_records = call_args[1]["Records"]
        self.assertEqual(len(kinesis_records), 1)
        self.assertEqual(kinesis_records[0]["PartitionKey"], "AAPL")

    def test_partial_failure_retries(self):
        # First call: 1 failure; retry call: 0 failures
        lambda_function.kinesis_client.put_records.side_effect = [
            {
                "FailedRecordCount": 1,
                "Records": [{"ErrorCode": "ProvisionedThroughputExceededException", "ErrorMessage": "throttled"}],
            },
            {"FailedRecordCount": 0, "Records": [{"SequenceNumber": "1", "ShardId": "0"}]},
        ]

        records = [{"symbol": "TSLA", "open": 200.0, "high": 210.0, "low": 195.0,
                    "close": 205.0, "volume": 500000, "vwap": 202.0,
                    "timestamp": 1000, "num_trades": 1000, "ingestion_time": 2000}]

        with patch("lambda_function.time.sleep"):
            failed = lambda_function._put_to_kinesis(records)

        self.assertEqual(lambda_function.kinesis_client.put_records.call_count, 2)
        self.assertEqual(failed, 0)


class TestLambdaHandler(unittest.TestCase):

    def setUp(self):
        lambda_function.kinesis_client = MagicMock()
        lambda_function.kinesis_client.put_records.return_value = {
            "FailedRecordCount": 0,
            "Records": [],
        }

    @patch.object(lambda_function, "http")
    def test_handler_returns_200(self, mock_http):
        mock_http.request.return_value = _mock_snapshot_response([MOCK_TICKER])

        result = lambda_function.lambda_handler({}, MagicMock())

        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertIn("fetched", body)
        self.assertIn("published", body)


if __name__ == "__main__":
    unittest.main()
