# StockPulse — Real-Time Stock Market Data Pipeline on AWS

## Project Overview

StockPulse is a production-grade, real-time stock market data pipeline built entirely on AWS. It ingests live stock tick data from Polygon.io, streams it through Kinesis, transforms it into clean OHLCV (Open, High, Low, Close, Volume) aggregates using PySpark, stores it in S3/Redshift, and visualises it on a Grafana Cloud dashboard.

**This is NOT a trading bot.** The goal is to build a complete, end-to-end AWS data engineering stack that covers ingestion, streaming, transformation, storage, querying, monitoring, and visualisation — all production-grade.

---

## Architecture

```
Polygon.io REST API (stock tick data)
         │
         ▼
Amazon EventBridge (scheduled rule, 1-min interval)
         │
         ▼
AWS Lambda — Ingester Function
  (fetches tick data from Polygon.io, pushes to Kinesis)
         │
         ▼
Amazon Kinesis Data Streams
  (real-time event stream, configurable shards)
         │
         ▼
AWS Lambda — Processor Function
  (consumes from Kinesis, writes raw Parquet to S3)
         │
         ▼
Amazon S3 — Raw Zone (s3://stockpulse-raw/)
  (raw tick data as Parquet, partitioned by date/symbol)
         │
         ▼
AWS Glue PySpark ETL Job
  (transforms raw tick data → clean OHLCV aggregates)
         │
         ▼
Amazon S3 — Processed Zone (s3://stockpulse-processed/)
  (clean OHLCV Parquet, partitioned by date/symbol)
         │
         ▼
┌─────────────────────────────────────────────┐
│  AWS Glue Data Catalog (metadata registry)  │
│  via Glue Crawler                           │
└─────────────────────────────────────────────┘
         │
         ├──────────────────────┐
         ▼                      ▼
Amazon Athena              Amazon Redshift Serverless
(ad-hoc SQL queries)       (analytical warehouse)
         │                      │
         └──────────┬───────────┘
                    ▼
            Grafana Cloud
        (live dashboard + panels)
```

---

## Tech Stack

| Layer | Service | Purpose |
|---|---|---|
| Data Source | Polygon.io REST API | Live and historical stock tick data |
| Scheduling | Amazon EventBridge | Triggers Lambda ingester on a cron schedule |
| Ingestion | AWS Lambda (Ingester) | Fetches data from Polygon.io, pushes to Kinesis |
| Streaming | Amazon Kinesis Data Streams | Real-time event stream buffer |
| Raw Processing | AWS Lambda (Processor) | Consumes Kinesis, writes raw Parquet to S3 |
| Storage (Raw) | Amazon S3 | Raw tick data in Parquet format |
| Transformation | AWS Glue PySpark ETL | Raw tick → clean OHLCV aggregation |
| Storage (Processed) | Amazon S3 | Clean OHLCV Parquet files |
| Metadata | AWS Glue Data Catalog + Crawler | Schema registry and table definitions |
| Ad-hoc Query | Amazon Athena | Serverless SQL on S3 data |
| Analytical Warehouse | Amazon Redshift Serverless | High-performance analytical queries |
| Visualisation | Grafana Cloud (free tier) | Live dashboards with price/volume panels |
| Monitoring | Amazon CloudWatch + DLQ | Alarms, logs, dead-letter queue for failures |
| IaC (optional) | AWS CDK or CloudFormation | Infrastructure as Code |

**Languages:** Python 3.11+ (Lambda, Glue), SQL (Athena/Redshift)

---

## Data Source — Polygon.io API

### API Details

- **Provider:** Polygon.io (https://polygon.io)
- **Plan:** Free tier (5 API calls/min, 2 years of historical data, 15-min delayed data) — sufficient for this project
- **Auth:** API key passed as `apiKey` query parameter or `Authorization: Bearer <key>` header

### Key Endpoints

**1. Aggregates (Bars) — Primary endpoint for this project**
```
GET https://api.polygon.io/v2/aggs/ticker/{stocksTicker}/range/{multiplier}/{timespan}/{from}/{to}
```
- `stocksTicker`: e.g., `AAPL`, `MSFT`, `GOOGL`, `TSLA`, `AMZN`
- `multiplier`: e.g., `1`
- `timespan`: `minute`, `hour`, `day`
- `from` / `to`: Date in `YYYY-MM-DD` or Unix ms timestamp
- Returns: Array of bar objects with `o` (open), `h` (high), `l` (low), `c` (close), `v` (volume), `t` (timestamp), `n` (number of trades), `vw` (volume-weighted avg price)

Example response:
```json
{
  "ticker": "AAPL",
  "queryCount": 10,
  "resultsCount": 10,
  "adjusted": true,
  "results": [
    {
      "v": 70790813,
      "vw": 131.6292,
      "o": 130.465,
      "c": 131.46,
      "h": 133.04,
      "l": 129.47,
      "t": 1577941200000,
      "n": 456789
    }
  ],
  "status": "OK",
  "request_id": "abc123",
  "count": 10
}
```

**2. Snapshot — All Tickers (for broader market data)**
```
GET https://api.polygon.io/v2/snapshot/locale/us/markets/stocks/tickers
```

**3. Previous Close**
```
GET https://api.polygon.io/v2/aggs/ticker/{stocksTicker}/prev
```

### Symbols to Track

Start with these 10 symbols for the MVP:
```
AAPL, MSFT, GOOGL, AMZN, TSLA, META, NVDA, JPM, V, JNJ
```

### Rate Limiting

- Free tier: 5 requests per minute
- Lambda ingester must respect this — use a single batch call per invocation, not per-symbol calls
- Implement exponential backoff on 429 responses

---

## Detailed Component Specifications

### 1. S3 Bucket Structure

```
stockpulse-data/
├── raw/
│   └── year=YYYY/month=MM/day=DD/
│       └── {symbol}_{timestamp}.parquet
├── processed/
│   └── year=YYYY/month=MM/day=DD/
│       └── ohlcv_{symbol}_{date}.parquet
├── archive/
│   └── (lifecycle rule moves raw data here after 7 days)
└── athena-results/
    └── (Athena query output)
```

**S3 Configuration:**
- Bucket versioning: enabled
- Server-side encryption: SSE-S3 (AES-256)
- Lifecycle rules: raw/ → archive/ after 7 days, archive/ → delete after 30 days
- Block all public access: enabled

### 2. IAM Roles and Policies

**Lambda Ingester Role** (`stockpulse-ingester-role`):
- `AmazonKinesisFullAccess` (scoped to stockpulse stream)
- `AmazonS3ReadOnlyAccess` (for config, if needed)
- `AWSLambdaBasicExecutionRole` (CloudWatch Logs)
- Custom inline policy for Polygon.io Secrets Manager access

**Lambda Processor Role** (`stockpulse-processor-role`):
- `AmazonKinesisReadOnlyAccess` (scoped to stockpulse stream)
- `AmazonS3FullAccess` (scoped to stockpulse-data bucket)
- `AWSLambdaBasicExecutionRole`

**Glue ETL Role** (`stockpulse-glue-role`):
- `AmazonS3FullAccess` (scoped to stockpulse-data bucket)
- `AWSGlueServiceRole`
- `AWSGlueConsoleFullAccess`

**Redshift Serverless Role** (`stockpulse-redshift-role`):
- `AmazonS3ReadOnlyAccess` (for COPY command)
- `AmazonRedshiftAllCommandsFullAccess`

### 3. EventBridge Scheduler

```json
{
  "Name": "stockpulse-ingester-schedule",
  "ScheduleExpression": "rate(1 minute)",
  "Target": {
    "Arn": "arn:aws:lambda:<region>:<account>:function:stockpulse-ingester",
    "RoleArn": "arn:aws:iam::<account>:role/stockpulse-eventbridge-role"
  },
  "State": "ENABLED"
}
```

- Triggers Lambda ingester every 1 minute during market hours
- Can optionally add a market-hours-only schedule: `cron(*/1 14-21 ? * MON-FRI *)` (9:30 AM - 4 PM ET in UTC)

### 4. Lambda — Ingester Function

**Runtime:** Python 3.11  
**Memory:** 256 MB  
**Timeout:** 60 seconds  
**Handler:** `lambda_function.lambda_handler`

**Functionality:**
1. Read Polygon.io API key from environment variable (or Secrets Manager)
2. For each tracked symbol, call Polygon.io Aggregates API for the last 1-minute bar
3. Batch all results into a single payload
4. Put record(s) to Kinesis Data Stream using `boto3.client('kinesis').put_records()`
5. Log success/failure counts to CloudWatch

**Key code structure:**
```python
# lambda_ingester/lambda_function.py
import json
import os
import time
import boto3
import urllib3

POLYGON_API_KEY = os.environ['POLYGON_API_KEY']
KINESIS_STREAM_NAME = os.environ['KINESIS_STREAM_NAME']
SYMBOLS = os.environ.get('SYMBOLS', 'AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ').split(',')
BASE_URL = 'https://api.polygon.io/v2/aggs/ticker'

kinesis_client = boto3.client('kinesis')
http = urllib3.PoolManager()

def lambda_handler(event, context):
    records = []
    
    for symbol in SYMBOLS:
        try:
            # Fetch previous day's aggregates (free tier = 15-min delay)
            url = f"{BASE_URL}/{symbol}/prev?adjusted=true&apiKey={POLYGON_API_KEY}"
            response = http.request('GET', url)
            data = json.loads(response.data.decode('utf-8'))
            
            if data.get('resultsCount', 0) > 0:
                for result in data['results']:
                    record = {
                        'symbol': symbol,
                        'open': result['o'],
                        'high': result['h'],
                        'low': result['l'],
                        'close': result['c'],
                        'volume': result['v'],
                        'vwap': result.get('vw'),
                        'timestamp': result['t'],
                        'num_trades': result.get('n'),
                        'ingestion_time': int(time.time() * 1000)
                    }
                    records.append({
                        'Data': json.dumps(record).encode('utf-8'),
                        'PartitionKey': symbol
                    })
        except Exception as e:
            print(f"Error fetching {symbol}: {e}")
    
    # Batch put to Kinesis (max 500 records per call)
    if records:
        response = kinesis_client.put_records(
            StreamName=KINESIS_STREAM_NAME,
            Records=records[:500]
        )
        failed = response.get('FailedRecordCount', 0)
        print(f"Put {len(records)} records, {failed} failed")
    
    return {'statusCode': 200, 'body': f'Processed {len(records)} records'}
```

**Dependencies (requirements.txt):**
```
urllib3
```
(boto3 is included in Lambda runtime)

**Environment Variables:**
```
POLYGON_API_KEY=<your-api-key>
KINESIS_STREAM_NAME=stockpulse-stream
SYMBOLS=AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ
```

### 5. Kinesis Data Streams

**Stream Name:** `stockpulse-stream`

**Configuration:**
- Shard count: 1 (sufficient for 10 symbols at 1-min intervals — well under 1 MB/s per shard)
- Retention period: 24 hours (default)
- Encryption: SSE with AWS managed key
- Enhanced fan-out: not needed for single consumer

**Partition Key Strategy:** Use stock symbol as partition key to keep same-symbol events on the same shard (important if scaling to multiple shards later)

### 6. Lambda — Processor Function

**Runtime:** Python 3.11  
**Memory:** 512 MB  
**Timeout:** 120 seconds  
**Trigger:** Kinesis Data Stream (batch size: 100, starting position: LATEST)

**Functionality:**
1. Receive batch of Kinesis records
2. Decode and parse each record
3. Convert to Parquet using PyArrow
4. Write Parquet file to S3 raw/ prefix with Hive-style partitioning
5. Handle failures gracefully — send to DLQ if record processing fails

**Key code structure:**
```python
# lambda_processor/lambda_function.py
import json
import os
import base64
from datetime import datetime
import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO

S3_BUCKET = os.environ['S3_BUCKET']
s3_client = boto3.client('s3')

SCHEMA = pa.schema([
    ('symbol', pa.string()),
    ('open', pa.float64()),
    ('high', pa.float64()),
    ('low', pa.float64()),
    ('close', pa.float64()),
    ('volume', pa.int64()),
    ('vwap', pa.float64()),
    ('timestamp', pa.int64()),
    ('num_trades', pa.int64()),
    ('ingestion_time', pa.int64()),
])

def lambda_handler(event, context):
    records_data = {field.name: [] for field in SCHEMA}
    
    for record in event['Records']:
        try:
            payload = json.loads(base64.b64decode(record['kinesis']['data']).decode('utf-8'))
            for field in SCHEMA:
                records_data[field.name].append(payload.get(field.name))
        except Exception as e:
            print(f"Error processing record: {e}")
            continue
    
    if any(len(v) > 0 for v in records_data.values()):
        table = pa.table(records_data, schema=SCHEMA)
        
        # Write Parquet to S3 with partitioning
        now = datetime.utcnow()
        key = f"raw/year={now.year}/month={now.month:02d}/day={now.day:02d}/batch_{now.strftime('%H%M%S')}_{context.aws_request_id[:8]}.parquet"
        
        buffer = BytesIO()
        pq.write_table(table, buffer, compression='snappy')
        buffer.seek(0)
        
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=buffer.getvalue()
        )
        print(f"Wrote {table.num_rows} records to s3://{S3_BUCKET}/{key}")
    
    return {'statusCode': 200}
```

**Lambda Layer:** Create a Lambda Layer with `pyarrow` pre-built for Lambda's Amazon Linux 2 runtime.

**Environment Variables:**
```
S3_BUCKET=stockpulse-data
```

### 7. AWS Glue — PySpark ETL Job

**Job Name:** `stockpulse-ohlcv-transform`  
**Type:** Spark  
**Glue Version:** 4.0  
**Worker Type:** G.1X  
**Number of Workers:** 2  
**Job Language:** Python 3  
**Script Location:** `s3://stockpulse-scripts/glue/ohlcv_transform.py`

**Transformation Logic:**
1. Read raw Parquet files from `s3://stockpulse-data/raw/`
2. Deduplicate records (same symbol + timestamp)
3. Handle nulls (coalesce VWAP, fill missing num_trades with 0)
4. Compute OHLCV aggregates per symbol per time interval (1-min, 5-min, 1-hour, 1-day)
5. Add derived columns: `price_change`, `price_change_pct`, `is_market_hours`
6. Write processed Parquet to `s3://stockpulse-data/processed/` with Hive partitioning
7. Update Glue Data Catalog

**Key code structure:**
```python
# glue/ohlcv_transform.py
import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'S3_INPUT_PATH', 'S3_OUTPUT_PATH'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Read raw data
raw_df = spark.read.parquet(args['S3_INPUT_PATH'])

# Deduplicate
deduped_df = raw_df.dropDuplicates(['symbol', 'timestamp'])

# Handle nulls
clean_df = deduped_df \
    .withColumn('vwap', F.coalesce(F.col('vwap'), F.col('close'))) \
    .withColumn('num_trades', F.coalesce(F.col('num_trades'), F.lit(0))) \
    .filter(F.col('symbol').isNotNull() & F.col('timestamp').isNotNull())

# Convert epoch ms to timestamp
clean_df = clean_df \
    .withColumn('event_time', F.from_unixtime(F.col('timestamp') / 1000).cast('timestamp')) \
    .withColumn('trade_date', F.to_date('event_time'))

# Add derived columns
clean_df = clean_df \
    .withColumn('price_change', F.col('close') - F.col('open')) \
    .withColumn('price_change_pct', 
                F.when(F.col('open') != 0, 
                       ((F.col('close') - F.col('open')) / F.col('open')) * 100)
                .otherwise(0)) \
    .withColumn('hour', F.hour('event_time')) \
    .withColumn('is_market_hours', 
                F.when((F.hour('event_time') >= 9) & (F.hour('event_time') < 16), True)
                .otherwise(False))

# Write processed data with partitioning
clean_df.write \
    .mode('append') \
    .partitionBy('trade_date', 'symbol') \
    .parquet(args['S3_OUTPUT_PATH'])

job.commit()
```

**Job Parameters:**
```
--S3_INPUT_PATH = s3://stockpulse-data/raw/
--S3_OUTPUT_PATH = s3://stockpulse-data/processed/
```

**Glue Trigger:** Schedule the job to run every hour using a Glue Trigger, or on-demand via the console.

### 8. Glue Crawler

**Crawler Name:** `stockpulse-crawler`  
**Database:** `stockpulse_db`  
**Target:** `s3://stockpulse-data/processed/`  
**Schedule:** Run after each Glue ETL job completes  
**Schema change policy:** Add new columns only, log changes  
**Table prefix:** `sp_`

This registers the processed Parquet data as a queryable table in the Glue Data Catalog, which both Athena and Redshift Spectrum can use.

### 9. Amazon Athena

**Workgroup:** `stockpulse-workgroup`  
**Output location:** `s3://stockpulse-data/athena-results/`  
**Database:** `stockpulse_db` (from Glue Data Catalog)

**Sample queries to validate:**
```sql
-- Latest OHLCV data per symbol
SELECT symbol, trade_date, open, high, low, close, volume, price_change_pct
FROM sp_processed
WHERE trade_date = current_date
ORDER BY symbol, event_time DESC;

-- Top movers of the day
SELECT symbol, 
       MAX(price_change_pct) as max_gain_pct,
       MIN(price_change_pct) as max_loss_pct,
       SUM(volume) as total_volume
FROM sp_processed
WHERE trade_date = current_date
GROUP BY symbol
ORDER BY max_gain_pct DESC;

-- Volume spikes (above 2x average)
SELECT symbol, event_time, volume,
       AVG(volume) OVER (PARTITION BY symbol ORDER BY event_time ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING) as avg_vol
FROM sp_processed
WHERE trade_date = current_date
HAVING volume > 2 * avg_vol;
```

### 10. Amazon Redshift Serverless

**Namespace:** `stockpulse-ns`  
**Workgroup:** `stockpulse-wg`  
**Base capacity:** 8 RPUs (minimum for serverless)  
**Database:** `stockpulse`  
**Schema:** `public`

**Table DDL:**
```sql
CREATE TABLE public.ohlcv (
    symbol          VARCHAR(10)     NOT NULL,
    open            DECIMAL(12,4)   NOT NULL,
    high            DECIMAL(12,4)   NOT NULL,
    low             DECIMAL(12,4)   NOT NULL,
    close           DECIMAL(12,4)   NOT NULL,
    volume          BIGINT          NOT NULL,
    vwap            DECIMAL(12,4),
    timestamp_ms    BIGINT          NOT NULL,
    num_trades      BIGINT          DEFAULT 0,
    event_time      TIMESTAMP       NOT NULL,
    trade_date      DATE            NOT NULL,
    price_change    DECIMAL(12,4),
    price_change_pct DECIMAL(8,4),
    ingestion_time  BIGINT,
    PRIMARY KEY (symbol, timestamp_ms)
)
DISTSTYLE KEY
DISTKEY (symbol)
SORTKEY (trade_date, event_time);
```

**COPY Command (load from S3):**
```sql
COPY public.ohlcv
FROM 's3://stockpulse-data/processed/'
IAM_ROLE 'arn:aws:iam::<account>:role/stockpulse-redshift-role'
FORMAT AS PARQUET;
```

### 11. Grafana Cloud Dashboard

**Setup:**
- Sign up for Grafana Cloud free tier (https://grafana.com/products/cloud/)
- Create a new dashboard: "StockPulse — Live Market Data"

**Data Source Options (pick one):**

**Option A — Lambda + API Gateway as JSON datasource (recommended for free tier):**
1. Create a Lambda function that queries Redshift Serverless and returns JSON
2. Expose via API Gateway (REST API)
3. Configure Grafana's JSON API datasource plugin to point to the API Gateway URL

**Option B — Redshift direct connection:**
1. Use Grafana's native PostgreSQL datasource (Redshift is PostgreSQL-compatible)
2. Configure with Redshift Serverless endpoint, database, and credentials
3. Requires Redshift to be publicly accessible or Grafana Cloud IP whitelisted

**Dashboard Panels:**
1. **Price Line Chart** — Close price over time per symbol (line chart, multi-series)
2. **Volume Bar Chart** — Volume per symbol per interval (bar chart)
3. **Top Movers Table** — Symbols ranked by price_change_pct (table panel)
4. **Pipeline Latency Gauge** — Time difference between `timestamp` and `ingestion_time` (gauge)
5. **Records Processed Counter** — Total records ingested today (stat panel)

### 12. Monitoring and Fault Tolerance

**CloudWatch Alarms:**
```
1. Lambda Ingester Errors    → Metric: Errors > 0         → SNS notification
2. Lambda Processor Errors   → Metric: Errors > 0         → SNS notification
3. Kinesis Iterator Age      → Metric: GetRecords.IteratorAgeMilliseconds > 60000  → SNS
4. Glue Job Failures         → Metric: glue.driver.aggregate.numFailedTasks > 0    → SNS
5. Lambda Throttles          → Metric: Throttles > 0       → SNS notification
```

**Dead Letter Queue (DLQ):**
- Create an SQS queue: `stockpulse-dlq`
- Configure Lambda Processor's event source mapping with `OnFailure` destination pointing to the DLQ
- Failed Kinesis batch records are sent to DLQ for manual inspection

**S3 Lifecycle Rules:**
```json
{
  "Rules": [
    {
      "ID": "archive-raw",
      "Filter": { "Prefix": "raw/" },
      "Status": "Enabled",
      "Transitions": [
        { "Days": 7, "StorageClass": "GLACIER_IR" }
      ]
    },
    {
      "ID": "delete-archive",
      "Filter": { "Prefix": "archive/" },
      "Status": "Enabled",
      "Expiration": { "Days": 30 }
    }
  ]
}
```

**Failure Scenarios to Test:**
1. Polygon.io API is down → Lambda should log error and continue with other symbols
2. Kinesis PutRecords partial failure → Retry failed records with backoff
3. Glue job fails mid-run → Job bookmark ensures no re-processing on next run
4. Redshift COPY fails → Alert via CloudWatch, data stays in S3 (no data loss)

---

## Project Directory Structure

```
stockpulse/
├── README.md
├── .gitignore
├── infrastructure/
│   ├── cloudformation/
│   │   └── stockpulse-stack.yaml          # (optional) CFn template
│   └── setup/
│       └── create_resources.sh            # CLI script to create all AWS resources
├── lambda/
│   ├── ingester/
│   │   ├── lambda_function.py
│   │   └── requirements.txt
│   └── processor/
│       ├── lambda_function.py
│       └── requirements.txt
├── glue/
│   └── ohlcv_transform.py
├── sql/
│   ├── redshift_ddl.sql
│   ├── athena_queries.sql
│   └── redshift_copy.sql
├── grafana/
│   └── dashboard.json                     # Exported Grafana dashboard config
├── scripts/
│   ├── deploy_lambda.sh                   # Package and deploy Lambda functions
│   ├── upload_glue_script.sh              # Upload Glue script to S3
│   └── run_glue_job.sh                    # Trigger Glue job
├── tests/
│   ├── test_ingester.py
│   ├── test_processor.py
│   └── test_glue_transform.py
├── docs/
│   └── architecture_diagram.png
└── config/
    └── symbols.json                       # List of tracked stock symbols
```

---

## Implementation Order (Phase by Phase)

### Phase 1 — Foundation & Setup
**What to build:**
- S3 bucket with raw/, processed/, archive/, athena-results/ prefixes
- IAM roles for Lambda Ingester, Lambda Processor, Glue, Redshift
- Store Polygon.io API key in environment variable (or Secrets Manager)
- Basic `.gitignore`, `README.md`, project directory structure

**Validation:** AWS console shows bucket created with correct prefix structure, IAM roles visible in IAM console.

### Phase 2 — Ingestion Layer
**What to build:**
- Lambda Ingester function (Python 3.11)
- EventBridge scheduled rule (rate: 1 minute)
- Test Polygon.io API connectivity
- Verify Lambda can write to Kinesis

**Validation:** EventBridge triggers Lambda → Lambda fetches from Polygon.io → records arrive in Kinesis (verify via Kinesis console monitoring tab).

### Phase 3 — Streaming Layer
**What to build:**
- Kinesis Data Stream (`stockpulse-stream`, 1 shard)
- Lambda Processor function with Kinesis trigger
- PyArrow Lambda Layer for Parquet writing
- Kinesis → Lambda Processor → S3 raw/ path

**Validation:** Raw Parquet files appear in `s3://stockpulse-data/raw/year=.../month=.../day=.../` — download one and verify schema with `pyarrow.parquet.read_table()`.

### Phase 4 — Transformation Layer
**What to build:**
- Glue PySpark ETL job (`ohlcv_transform.py`)
- Upload script to S3
- Glue Crawler to catalog processed data
- Run Glue job and verify output

**Validation:** Processed OHLCV Parquet files in `s3://stockpulse-data/processed/`, Glue Data Catalog shows `sp_processed` table with correct schema.

### Phase 5 — Query Layer
**What to build:**
- Athena workgroup + output location
- Create Athena external table (or use Glue Catalog table directly)
- Run sample Athena queries to verify data
- Provision Redshift Serverless (namespace + workgroup)
- Create Redshift table (DDL above)
- Load data via COPY command
- Run same queries on Redshift and compare performance

**Validation:** Both Athena and Redshift return correct OHLCV data. Document query latency comparison.

### Phase 6 — Visualisation Layer
**What to build:**
- Grafana Cloud account setup
- Data source connection (JSON API via Lambda+API Gateway OR direct Redshift)
- Dashboard with 5 panels: price chart, volume bars, top movers, latency gauge, records counter
- Configure auto-refresh interval

**Validation:** Grafana dashboard shows live stock data updating automatically.

### Phase 7 — Monitoring & Hardening
**What to build:**
- CloudWatch alarms (5 alarms listed above)
- SQS dead-letter queue for failed Kinesis processing
- S3 lifecycle rules
- Error handling improvements in Lambda functions
- Test failure scenarios

**Validation:** Intentionally trigger failures (bad API key, invalid data, throttle Lambda) and verify alarms fire, DLQ captures failed records, pipeline recovers.

### Phase 8 — Documentation & GitHub
**What to build:**
- Comprehensive README with architecture diagram
- Document design decisions and tradeoffs
- Add sample Grafana dashboard screenshot
- Push to GitHub
- Clean up any hardcoded values, add proper config management

**Validation:** Repo is public, README is clear, architecture diagram is included, all code is clean and documented.

---

## Environment Variables Summary

```bash
# Lambda Ingester
POLYGON_API_KEY=<your-polygon-api-key>
KINESIS_STREAM_NAME=stockpulse-stream
SYMBOLS=AAPL,MSFT,GOOGL,AMZN,TSLA,META,NVDA,JPM,V,JNJ

# Lambda Processor
S3_BUCKET=stockpulse-data

# Glue Job
S3_INPUT_PATH=s3://stockpulse-data/raw/
S3_OUTPUT_PATH=s3://stockpulse-data/processed/

# Redshift
REDSHIFT_HOST=<workgroup-endpoint>
REDSHIFT_DB=stockpulse
REDSHIFT_USER=admin
REDSHIFT_PORT=5439
```

---

## Design Decisions and Tradeoffs

| Decision | Why | Tradeoff |
|---|---|---|
| Kinesis over SQS | Need real-time ordered stream with replay capability | Higher cost per shard vs SQS, but data replay is critical |
| Parquet over JSON for S3 | Columnar format = 10x compression + faster query performance | Requires PyArrow in Lambda (adds cold start latency via layer) |
| Glue PySpark over Lambda for transformation | PySpark handles complex aggregations, window functions, and scales with data volume | Glue DPU cost + cold start (~2 min), but correct tool for analytical transformations |
| Redshift Serverless over provisioned | Pay-per-query, no idle cluster cost | Query latency slightly higher than provisioned, but cost-effective for a portfolio project |
| Athena AND Redshift | Athena for ad-hoc exploration, Redshift for dashboard queries | Two query engines to maintain, but demonstrates both skills |
| EventBridge over CloudWatch Events | EventBridge is the newer, recommended service | Functionally identical for simple cron, but EventBridge is the future |
| Symbol as Kinesis partition key | Ensures ordering per symbol, enables future multi-shard scaling | Potential hot shard if one symbol has 10x more data (unlikely for 10 symbols) |
| Snappy compression for Parquet | Best balance of compression ratio and read speed | Slightly less compression than gzip, but much faster decompression |
| Free tier Polygon.io | Sufficient for portfolio project, 15-min delay acceptable | Not truly real-time — delayed data, but pipeline architecture is identical to production |

---

## Cost Estimation (Monthly, Free Tier + Minimal Usage)

| Service | Estimated Cost | Notes |
|---|---|---|
| Lambda | ~$0 | Well within free tier (1M requests/month) |
| Kinesis | ~$15 | 1 shard × $0.015/hr × 730 hrs + PUT payload |
| S3 | ~$1–3 | Small data volume for 10 symbols |
| Glue | ~$5–10 | 2 DPU × $0.44/DPU-hr × runs |
| Athena | ~$0–2 | $5/TB scanned, very small scans |
| Redshift Serverless | ~$10–20 | 8 RPU minimum, pay per query |
| Grafana Cloud | $0 | Free tier |
| EventBridge | ~$0 | Free tier covers scheduled rules |
| CloudWatch | ~$0–1 | Logs + alarms |
| **Total** | **~$30–50/month** | Can reduce by pausing when not in use |

**Cost control tips:**
- Disable EventBridge rule when not actively developing
- Use Athena instead of Redshift for most queries during development
- Delete Kinesis stream when pausing (shards cost $0.015/hr even idle)
- Set up AWS Budgets alarm at $50/month

---

## GitHub Repository Setup

**Repo Name:** `stockpulse`  
**Description:** Real-time stock market data pipeline on AWS — Polygon.io → EventBridge → Lambda → Kinesis → S3 → Glue PySpark → Redshift Serverless + Athena → Grafana Cloud  
**Visibility:** Public  
**License:** MIT  

**.gitignore:**
```
__pycache__/
*.pyc
.env
*.zip
.DS_Store
node_modules/
.idea/
.vscode/
*.tfstate
*.tfstate.backup
```

---

## Notes for Claude Code

1. **Start with Phase 1** — get the foundation right before writing Lambda code
2. **Test each phase independently** before moving to the next — don't build the entire pipeline and then debug
3. **The Lambda Processor needs a PyArrow Lambda Layer** — this must be built for Amazon Linux 2 (arm64 or x86_64 depending on Lambda architecture). Build it using Docker:
   ```bash
   docker run -v $(pwd):/output amazonlinux:2 bash -c \
     "yum install -y python3-pip && pip3 install pyarrow -t /output/python/"
   ```
   Then zip and upload as a Lambda Layer.
4. **Polygon.io free tier has 5 req/min limit** — the ingester should batch all 10 symbols in one call if possible (use the snapshot endpoint), or make sequential calls with delays
5. **Glue jobs have ~2 min cold start** — this is normal, not a bug
6. **All S3 paths use Hive-style partitioning** (`year=YYYY/month=MM/day=DD/`) for Athena compatibility
7. **Redshift Serverless auto-pauses after idle period** — first query after pause will be slow (~30s warmup)
8. **Use `aws configure` with a dedicated IAM user or SSO profile** — never hardcode credentials
9. **The project GitHub URL will be:** `github.com/utkarshsingh1102/stockpulse`
