"""
StockPulse — AWS Glue PySpark ETL Job
Transforms raw tick Parquet data into clean OHLCV aggregates.

Job Name:    stockpulse-ohlcv-transform
Glue Version: 4.0
Worker Type: G.1X
Workers:     2

Job parameters (passed via --job-bookmark-option and --args):
  --JOB_NAME        stockpulse-ohlcv-transform
  --S3_INPUT_PATH   s3://stockpulse-data-us/raw/
  --S3_OUTPUT_PATH  s3://stockpulse-data-us/processed/

Run via AWS console, Glue trigger, or:
  aws glue start-job-run --job-name stockpulse-ohlcv-transform
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# ---------------------------------------------------------------------------
# Glue job initialisation
# ---------------------------------------------------------------------------
args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "S3_INPUT_PATH", "S3_OUTPUT_PATH"],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

S3_INPUT_PATH = args["S3_INPUT_PATH"]   # e.g. s3://stockpulse-data-us/raw/
S3_OUTPUT_PATH = args["S3_OUTPUT_PATH"] # e.g. s3://stockpulse-data-us/processed/

print(f"Reading raw data from: {S3_INPUT_PATH}")
print(f"Writing processed data to: {S3_OUTPUT_PATH}")

# ---------------------------------------------------------------------------
# 1. Read raw Parquet data
# ---------------------------------------------------------------------------
raw_df = spark.read.parquet(S3_INPUT_PATH)
raw_count = raw_df.count()
print(f"Raw records read: {raw_count}")

# ---------------------------------------------------------------------------
# 2. Deduplicate on (symbol, timestamp) — same bar may arrive multiple times
#    if the ingester retries or EventBridge fires twice in the same minute.
# ---------------------------------------------------------------------------
deduped_df = raw_df.dropDuplicates(["symbol", "timestamp"])
dedup_count = deduped_df.count()
print(f"After dedup: {dedup_count} records ({raw_count - dedup_count} duplicates removed)")

# ---------------------------------------------------------------------------
# 3. Handle nulls and cast types
# ---------------------------------------------------------------------------
clean_df = (
    deduped_df
    # VWAP: fall back to close price if missing
    .withColumn("vwap", F.coalesce(F.col("vwap"), F.col("close")))
    # num_trades: default to 0 if missing
    .withColumn("num_trades", F.coalesce(F.col("num_trades").cast("long"), F.lit(0L)))
    # volume: cast to long (stored as float64 in raw to handle None)
    .withColumn("volume", F.col("volume").cast("long"))
    # Drop rows with no symbol or no timestamp — cannot be keyed
    .filter(F.col("symbol").isNotNull() & F.col("timestamp").isNotNull())
    # Drop rows with no OHLC data
    .filter(
        F.col("open").isNotNull()
        & F.col("high").isNotNull()
        & F.col("low").isNotNull()
        & F.col("close").isNotNull()
    )
)

# ---------------------------------------------------------------------------
# 4. Convert epoch ms timestamp → proper timestamp + date columns
# ---------------------------------------------------------------------------
clean_df = (
    clean_df
    .withColumn("event_time", (F.col("timestamp") / 1000).cast("timestamp"))
    .withColumn("trade_date", F.to_date("event_time"))
    .withColumn("hour", F.hour("event_time"))
    .withColumn("minute", F.minute("event_time"))
)

# ---------------------------------------------------------------------------
# 5. Add derived financial columns
# ---------------------------------------------------------------------------
clean_df = (
    clean_df
    # Absolute and relative price change for the bar
    .withColumn("price_change", F.col("close") - F.col("open"))
    .withColumn(
        "price_change_pct",
        F.when(
            F.col("open") != 0,
            ((F.col("close") - F.col("open")) / F.col("open")) * 100,
        ).otherwise(F.lit(0.0)),
    )
    # True if bar falls within NYSE regular market hours (9:30–16:00 ET)
    # Note: event_time is in UTC; 9:30 ET = 14:30 UTC, 16:00 ET = 21:00 UTC
    .withColumn(
        "is_market_hours",
        F.when(
            (F.hour("event_time") > 14)
            | ((F.hour("event_time") == 14) & (F.minute("event_time") >= 30)),
            F.when(F.hour("event_time") < 21, F.lit(True)).otherwise(F.lit(False)),
        ).otherwise(F.lit(False)),
    )
    # Bar range as a fraction of open price (measure of volatility)
    .withColumn(
        "bar_range_pct",
        F.when(
            F.col("open") != 0,
            ((F.col("high") - F.col("low")) / F.col("open")) * 100,
        ).otherwise(F.lit(0.0)),
    )
)

# ---------------------------------------------------------------------------
# 6. Rolling volume average (10-bar trailing window per symbol)
#    Useful for Grafana "volume spike" panel queries
# ---------------------------------------------------------------------------
window_spec = (
    Window.partitionBy("symbol")
    .orderBy("timestamp")
    .rowsBetween(-10, -1)
)

clean_df = clean_df.withColumn(
    "avg_volume_10bar", F.avg("volume").over(window_spec)
)

final_count = clean_df.count()
print(f"Final record count after cleaning: {final_count}")

# ---------------------------------------------------------------------------
# 7. Write processed Parquet to S3 with Hive partitioning
#    Partitioned by trade_date then symbol for efficient date-range queries
# ---------------------------------------------------------------------------
(
    clean_df
    .write
    .mode("append")
    .partitionBy("trade_date", "symbol")
    .parquet(S3_OUTPUT_PATH)
)

print(f"Wrote {final_count} records to {S3_OUTPUT_PATH}")

# ---------------------------------------------------------------------------
# Commit job bookmark — ensures Glue doesn't reprocess already-seen files
# ---------------------------------------------------------------------------
job.commit()
print("Job committed successfully.")
