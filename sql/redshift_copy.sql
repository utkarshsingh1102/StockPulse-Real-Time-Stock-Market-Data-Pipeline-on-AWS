-- StockPulse — Redshift Serverless COPY Command
-- Loads processed OHLCV Parquet data from S3 into public.ohlcv table.
--
-- Prerequisites:
--   1. Run redshift_ddl.sql first to create the table
--   2. Replace <ACCOUNT_ID> and <REGION> with your actual values
--   3. Ensure the stockpulse-redshift-role has s3:GetObject on stockpulse-data

-- Full load (initial setup or after clearing the table)
COPY public.ohlcv (
    symbol,
    open,
    high,
    low,
    close,
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
FROM 's3://stockpulse-data/processed/'
IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/stockpulse-redshift-role'
FORMAT AS PARQUET
SERIALIZETOJSON;


-- ---------------------------------------------------------------------------
-- Incremental load — load only today's partition
-- Replace YYYY-MM-DD with today's date or parameterise via a stored procedure
-- ---------------------------------------------------------------------------
-- COPY public.ohlcv
-- FROM 's3://stockpulse-data/processed/trade_date=YYYY-MM-DD/'
-- IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/stockpulse-redshift-role'
-- FORMAT AS PARQUET
-- SERIALIZETOJSON;


-- ---------------------------------------------------------------------------
-- Verify the load
-- ---------------------------------------------------------------------------
SELECT
    trade_date,
    COUNT(*) AS row_count,
    COUNT(DISTINCT symbol) AS symbol_count
FROM public.ohlcv
GROUP BY trade_date
ORDER BY trade_date DESC
LIMIT 10;
