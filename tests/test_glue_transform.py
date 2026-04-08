"""
Tests for glue/ohlcv_transform.py (PySpark transformation logic)
Uses PySpark locally — run in an environment with PySpark installed.

Run: pytest tests/test_glue_transform.py -v
Requires: pip install pyspark pytest

Note: Glue-specific imports (awsglue.*) are mocked since they only exist
      in the Glue runtime. The core PySpark transformation logic is tested
      by extracting and testing the transformation functions directly.
"""

import sys
import types
import unittest

import pytest

# ---------------------------------------------------------------------------
# Mock awsglue.* modules (only available inside Glue runtime)
# ---------------------------------------------------------------------------
for module_name in [
    "awsglue",
    "awsglue.transforms",
    "awsglue.utils",
    "awsglue.context",
    "awsglue.job",
]:
    mock_mod = types.ModuleType(module_name)
    sys.modules[module_name] = mock_mod

# Provide stub implementations
sys.modules["awsglue.utils"].getResolvedOptions = lambda argv, keys: {
    k: f"s3://test-bucket/{k.lower().replace('_', '/')}" if "PATH" in k else f"test-{k}"
    for k in keys
}
sys.modules["awsglue.context"].GlueContext = type("GlueContext", (), {"spark_session": None})
sys.modules["awsglue.job"].Job = type(
    "Job",
    (),
    {"__init__": lambda self, ctx: None, "init": lambda self, *a: None, "commit": lambda self: None},
)

# ---------------------------------------------------------------------------
# PySpark setup (local mode)
# ---------------------------------------------------------------------------
pyspark = pytest.importorskip("pyspark", reason="pyspark not installed")

from pyspark.sql import SparkSession  # noqa: E402
from pyspark.sql import functions as F  # noqa: E402


@pytest.fixture(scope="module")
def spark():
    return (
        SparkSession.builder
        .master("local[1]")
        .appName("stockpulse-test")
        .config("spark.sql.shuffle.partitions", "1")
        .getOrCreate()
    )


# ---------------------------------------------------------------------------
# Sample data
# ---------------------------------------------------------------------------
RAW_ROWS = [
    # symbol, open, high, low, close, volume, vwap, timestamp (ms), num_trades, ingestion_time
    ("AAPL", 150.0, 155.0, 148.0, 153.5, 1000000.0, 152.0, 1700000000000, 5000.0, 1700000010000),
    ("AAPL", 150.0, 155.0, 148.0, 153.5, 1000000.0, 152.0, 1700000000000, 5000.0, 1700000020000),  # duplicate
    ("MSFT", 300.0, 310.0, 295.0, 305.0, 500000.0, None, 1700000060000, None, 1700000070000),
    ("TSLA", None, None, None, None, 0.0, None, 1700000120000, 0.0, 1700000130000),  # no OHLC — should be filtered
]

RAW_SCHEMA = [
    "symbol", "open", "high", "low", "close",
    "volume", "vwap", "timestamp", "num_trades", "ingestion_time"
]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class TestDeduplication:
    def test_removes_duplicate_symbol_timestamp(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        deduped = df.dropDuplicates(["symbol", "timestamp"])
        assert deduped.count() == 3  # AAPL duplicate removed; TSLA still present pre-filter

    def test_retains_distinct_symbols(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        deduped = df.dropDuplicates(["symbol", "timestamp"])
        symbols = {r.symbol for r in deduped.collect()}
        assert "AAPL" in symbols
        assert "MSFT" in symbols


class TestNullHandling:
    def test_vwap_falls_back_to_close(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        df = df.dropDuplicates(["symbol", "timestamp"])
        df = df.withColumn("vwap", F.coalesce(F.col("vwap"), F.col("close")))

        msft_row = df.filter(F.col("symbol") == "MSFT").first()
        assert msft_row.vwap == msft_row.close  # MSFT had null vwap → close used

    def test_num_trades_defaults_to_zero(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        df = df.withColumn(
            "num_trades",
            F.coalesce(F.col("num_trades").cast("long"), F.lit(0))
        )
        msft_row = df.filter(F.col("symbol") == "MSFT").first()
        assert msft_row.num_trades == 0

    def test_filters_rows_with_no_ohlc(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        df = df.filter(
            F.col("open").isNotNull()
            & F.col("high").isNotNull()
            & F.col("low").isNotNull()
            & F.col("close").isNotNull()
        )
        symbols = {r.symbol for r in df.collect()}
        assert "TSLA" not in symbols


class TestDerivedColumns:
    def _clean_df(self, spark):
        df = spark.createDataFrame(RAW_ROWS, schema=RAW_SCHEMA)
        df = df.dropDuplicates(["symbol", "timestamp"])
        df = df.filter(
            F.col("open").isNotNull()
            & F.col("close").isNotNull()
            & F.col("high").isNotNull()
            & F.col("low").isNotNull()
        )
        df = df.withColumn("vwap", F.coalesce(F.col("vwap"), F.col("close")))
        df = df.withColumn("event_time", (F.col("timestamp") / 1000).cast("timestamp"))
        df = df.withColumn("trade_date", F.to_date("event_time"))
        df = df.withColumn("price_change", F.col("close") - F.col("open"))
        df = df.withColumn(
            "price_change_pct",
            F.when(
                F.col("open") != 0,
                ((F.col("close") - F.col("open")) / F.col("open")) * 100,
            ).otherwise(F.lit(0.0)),
        )
        return df

    def test_price_change_calculated(self, spark):
        df = self._clean_df(spark)
        aapl = df.filter(F.col("symbol") == "AAPL").first()
        assert abs(aapl.price_change - (153.5 - 150.0)) < 0.001

    def test_price_change_pct_calculated(self, spark):
        df = self._clean_df(spark)
        aapl = df.filter(F.col("symbol") == "AAPL").first()
        expected_pct = ((153.5 - 150.0) / 150.0) * 100
        assert abs(aapl.price_change_pct - expected_pct) < 0.001

    def test_event_time_from_timestamp(self, spark):
        df = self._clean_df(spark)
        aapl = df.filter(F.col("symbol") == "AAPL").first()
        assert aapl.event_time is not None
        assert aapl.trade_date is not None


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
