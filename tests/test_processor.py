"""
Tests for lambda/processor/lambda_function.py
Run: pytest tests/test_processor.py -v
Requires: pip install pyarrow pytest
"""

import base64
import json
import os
import sys
import unittest
from io import BytesIO
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub boto3 before import
# ---------------------------------------------------------------------------
boto3_mock = MagicMock()
sys.modules["boto3"] = boto3_mock

# Load central config (reads .env automatically in local dev)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from config import settings  # noqa: E402

os.environ.setdefault("S3_BUCKET", settings.S3_BUCKET)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "processor"))
import lambda_function  # noqa: E402

import pyarrow.parquet as pq  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _make_kinesis_record(payload: dict) -> dict:
    encoded = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("utf-8")
    return {
        "kinesis": {
            "data": encoded,
            "sequenceNumber": "12345",
            "approximateArrivalTimestamp": 1700000000.0,
        }
    }


VALID_PAYLOAD = {
    "symbol": "AAPL",
    "open": 150.0,
    "high": 155.0,
    "low": 148.0,
    "close": 153.5,
    "volume": 1000000.0,
    "vwap": 152.0,
    "timestamp": 1700000000000,
    "num_trades": 5000.0,
    "ingestion_time": 1700000010000,
}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class TestDecodeKinesisRecord(unittest.TestCase):

    def test_valid_record_decoded(self):
        record = _make_kinesis_record(VALID_PAYLOAD)
        result = lambda_function._decode_kinesis_record(record)
        self.assertIsNotNone(result)
        self.assertEqual(result["symbol"], "AAPL")
        self.assertEqual(result["close"], 153.5)

    def test_invalid_base64_returns_none(self):
        bad_record = {"kinesis": {"data": "!!!not-base64!!!", "sequenceNumber": "1"}}
        result = lambda_function._decode_kinesis_record(bad_record)
        self.assertIsNone(result)

    def test_invalid_json_returns_none(self):
        bad_json = base64.b64encode(b"not json at all").decode("utf-8")
        record = {"kinesis": {"data": bad_json, "sequenceNumber": "1"}}
        result = lambda_function._decode_kinesis_record(record)
        self.assertIsNone(result)


class TestBuildArrowTable(unittest.TestCase):

    def test_table_has_correct_schema(self):
        table = lambda_function._build_arrow_table([VALID_PAYLOAD])
        self.assertEqual(table.num_rows, 1)
        self.assertIn("symbol", table.schema.names)
        self.assertIn("close", table.schema.names)
        self.assertIn("timestamp", table.schema.names)

    def test_table_handles_none_values(self):
        payload_with_none = {**VALID_PAYLOAD, "vwap": None, "num_trades": None}
        table = lambda_function._build_arrow_table([payload_with_none])
        self.assertEqual(table.num_rows, 1)

    def test_multiple_records(self):
        payloads = [VALID_PAYLOAD, {**VALID_PAYLOAD, "symbol": "MSFT", "close": 300.0}]
        table = lambda_function._build_arrow_table(payloads)
        self.assertEqual(table.num_rows, 2)


class TestS3Key(unittest.TestCase):

    def test_s3_key_format(self):
        from datetime import datetime, timezone
        now = datetime(2024, 1, 15, 14, 30, 0, tzinfo=timezone.utc)
        key = lambda_function._s3_key(now, "abc12345-xyz")
        self.assertTrue(key.startswith("raw/year=2024/month=01/day=15/"))
        self.assertIn("143000", key)
        self.assertIn("abc12345", key)
        self.assertTrue(key.endswith(".parquet"))


class TestWriteParquetToS3(unittest.TestCase):

    def setUp(self):
        lambda_function.s3_client = MagicMock()

    def test_writes_valid_parquet(self):
        table = lambda_function._build_arrow_table([VALID_PAYLOAD])
        lambda_function._write_parquet_to_s3(table, "raw/year=2024/month=01/day=15/test.parquet")

        call_args = lambda_function.s3_client.put_object.call_args[1]
        self.assertEqual(call_args["Bucket"], settings.S3_BUCKET)
        self.assertEqual(call_args["Key"], "raw/year=2024/month=01/day=15/test.parquet")

        # Verify the body is valid Parquet
        body_bytes = call_args["Body"]
        result_table = pq.read_table(BytesIO(body_bytes))
        self.assertEqual(result_table.num_rows, 1)


class TestLambdaHandler(unittest.TestCase):

    def setUp(self):
        lambda_function.s3_client = MagicMock()

    def test_handler_processes_valid_records(self):
        event = {"Records": [_make_kinesis_record(VALID_PAYLOAD)]}
        ctx = MagicMock()
        ctx.aws_request_id = "test-request-id-1234"

        result = lambda_function.lambda_handler(event, ctx)

        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["written"], 1)
        self.assertEqual(body["decode_failures"], 0)
        lambda_function.s3_client.put_object.assert_called_once()

    def test_handler_skips_bad_records(self):
        bad_record = {"kinesis": {"data": "!!!bad!!!", "sequenceNumber": "1"}}
        event = {"Records": [bad_record, _make_kinesis_record(VALID_PAYLOAD)]}
        ctx = MagicMock()
        ctx.aws_request_id = "test-request-id-5678"

        result = lambda_function.lambda_handler(event, ctx)

        body = json.loads(result["body"])
        self.assertEqual(body["written"], 1)
        self.assertEqual(body["decode_failures"], 1)

    def test_handler_returns_200_on_empty_after_decode_failure(self):
        bad_record = {"kinesis": {"data": "!!!bad!!!", "sequenceNumber": "1"}}
        event = {"Records": [bad_record]}
        ctx = MagicMock()
        ctx.aws_request_id = "test-no-valid"

        result = lambda_function.lambda_handler(event, ctx)
        self.assertEqual(result["statusCode"], 200)
        lambda_function.s3_client.put_object.assert_not_called()

    def test_s3_write_failure_raises(self):
        lambda_function.s3_client.put_object.side_effect = Exception("S3 unavailable")
        event = {"Records": [_make_kinesis_record(VALID_PAYLOAD)]}
        ctx = MagicMock()
        ctx.aws_request_id = "test-failure"

        with self.assertRaises(Exception, msg="S3 unavailable"):
            lambda_function.lambda_handler(event, ctx)


if __name__ == "__main__":
    unittest.main()
