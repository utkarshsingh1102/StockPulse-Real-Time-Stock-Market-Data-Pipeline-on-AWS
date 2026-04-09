-- StockPulse — Redshift Serverless DDL
-- Namespace: stockpulse-ns | Workgroup: stockpulse-wg | Database: stockpulse
--
-- Distribution: DISTKEY(symbol) keeps all rows for a symbol on the same node,
--               optimising JOIN and GROUP BY on symbol.
-- Sort key:     (trade_date, event_time) for efficient date-range scans.

-- Step 1: Drop existing table
DROP TABLE IF EXISTS public.ohlcv;

-- Step 2: Recreate with schema that exactly matches Parquet output from Glue
CREATE TABLE public.ohlcv (
    symbol              VARCHAR(10)     NOT NULL,
    "open"              DECIMAL(12, 4)  NOT NULL,
    high                DECIMAL(12, 4)  NOT NULL,
    low                 DECIMAL(12, 4)  NOT NULL,
    "close"             DECIMAL(12, 4)  NOT NULL,
    volume              BIGINT          NOT NULL DEFAULT 0,
    vwap                DECIMAL(12, 4),
    timestamp_ms        BIGINT          NOT NULL,
    num_trades          BIGINT          NOT NULL DEFAULT 0,
    event_time          TIMESTAMP       NOT NULL,
    trade_date          DATE            NOT NULL,
    price_change        DECIMAL(12, 4),
    price_change_pct    DECIMAL(8, 4),
    bar_range_pct       DECIMAL(8, 4),
    is_market_hours     BOOLEAN         DEFAULT FALSE,
    avg_volume_10bar    DECIMAL(18, 2),
    ingestion_time      BIGINT,
    PRIMARY KEY (symbol, timestamp_ms)
)
DISTSTYLE KEY
DISTKEY (symbol)
SORTKEY (trade_date, event_time);

-- Grant read access to reporting user (adjust as needed)
-- GRANT SELECT ON public.ohlcv TO reporting_user;
