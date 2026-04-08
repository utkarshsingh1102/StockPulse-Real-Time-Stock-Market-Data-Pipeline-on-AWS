-- StockPulse — Athena Validation Queries
-- Database: stockpulse_db  |  Table: sp_processed
-- Output location: s3://stockpulse-data-us/athena-results/
--
-- Run these after each Glue job + Crawler to validate processed data.

-- ---------------------------------------------------------------------------
-- 1. Latest OHLCV bar per symbol for today
-- ---------------------------------------------------------------------------
SELECT
    symbol,
    trade_date,
    open,
    high,
    low,
    close,
    volume,
    vwap,
    price_change_pct,
    is_market_hours
FROM stockpulse_db.sp_processed
WHERE trade_date = CURRENT_DATE
ORDER BY symbol, event_time DESC;


-- ---------------------------------------------------------------------------
-- 2. Top movers of the day (ranked by absolute price change %)
-- ---------------------------------------------------------------------------
SELECT
    symbol,
    ROUND(MAX(price_change_pct), 4)  AS max_gain_pct,
    ROUND(MIN(price_change_pct), 4)  AS max_loss_pct,
    ROUND(AVG(price_change_pct), 4)  AS avg_change_pct,
    SUM(volume)                       AS total_volume,
    COUNT(*)                          AS bar_count
FROM stockpulse_db.sp_processed
WHERE trade_date = CURRENT_DATE
GROUP BY symbol
ORDER BY ABS(MAX(price_change_pct)) DESC;


-- ---------------------------------------------------------------------------
-- 3. Volume spikes — bars where volume > 2× the 10-bar trailing average
-- ---------------------------------------------------------------------------
SELECT
    symbol,
    event_time,
    volume,
    ROUND(avg_volume_10bar, 0)                      AS trailing_avg_volume,
    ROUND(volume / NULLIF(avg_volume_10bar, 0), 2)  AS volume_ratio
FROM stockpulse_db.sp_processed
WHERE trade_date = CURRENT_DATE
  AND avg_volume_10bar IS NOT NULL
  AND volume > 2 * avg_volume_10bar
ORDER BY volume_ratio DESC;


-- ---------------------------------------------------------------------------
-- 4. Pipeline latency — how long between market bar and ingestion (ms)
-- ---------------------------------------------------------------------------
SELECT
    symbol,
    event_time,
    timestamp_ms,
    ingestion_time,
    (ingestion_time - timestamp_ms)              AS latency_ms,
    ROUND((ingestion_time - timestamp_ms) / 1000.0, 1) AS latency_sec
FROM stockpulse_db.sp_processed
WHERE trade_date = CURRENT_DATE
ORDER BY latency_ms DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 5. Daily OHLCV summary (collapsed from 1-min bars)
-- ---------------------------------------------------------------------------
SELECT
    symbol,
    trade_date,
    FIRST_VALUE(open)  OVER (PARTITION BY symbol, trade_date ORDER BY event_time ASC)  AS day_open,
    MAX(high)                                                                            AS day_high,
    MIN(low)                                                                             AS day_low,
    LAST_VALUE(close)  OVER (PARTITION BY symbol, trade_date ORDER BY event_time ASC
                             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)  AS day_close,
    SUM(volume)                                                                          AS day_volume
FROM stockpulse_db.sp_processed
WHERE trade_date >= DATE_ADD('day', -7, CURRENT_DATE)
GROUP BY symbol, trade_date, open, close, event_time
ORDER BY symbol, trade_date DESC;


-- ---------------------------------------------------------------------------
-- 6. Record count by date — sanity check for data completeness
-- ---------------------------------------------------------------------------
SELECT
    trade_date,
    symbol,
    COUNT(*) AS bar_count,
    MIN(event_time) AS first_bar,
    MAX(event_time) AS last_bar
FROM stockpulse_db.sp_processed
GROUP BY trade_date, symbol
ORDER BY trade_date DESC, symbol;
