# StockPulse — Real-Time Stock Market Data Pipeline on AWS

A production-grade, end-to-end AWS data engineering pipeline that ingests live stock tick data from Polygon.io, streams it through Kinesis, transforms it into clean OHLCV aggregates using PySpark (AWS Glue), stores it in S3 + Redshift Serverless, and visualises it on a Grafana Cloud dashboard.

**This is NOT a trading bot.** The goal is a complete AWS data engineering stack covering ingestion, streaming, transformation, storage, querying, monitoring, and visualisation.

---

## Architecture

```
Polygon.io REST API (stock tick data)
         │
         ▼
Amazon EventBridge (cron: every 1 min, market hours only)
         │
         ▼
AWS Lambda — Ingester
  (fetches tick data from Polygon.io → pushes to Kinesis)
         │
         ▼
Amazon Kinesis Data Streams (1 shard, 24h retention)
         │
         ▼
AWS Lambda — Processor
  (Kinesis consumer → writes raw Parquet to S3)
         │
         ▼
Amazon S3 — Raw Zone  s3://stockpulse-data/raw/
  (Parquet, Hive-partitioned: year=YYYY/month=MM/day=DD/)
         │
         ▼
AWS Glue PySpark ETL Job (ohlcv_transform.py)
  (dedup → clean → OHLCV aggregates + derived columns)
         │
         ▼
Amazon S3 — Processed Zone  s3://stockpulse-data/processed/
  (clean OHLCV Parquet, partitioned by trade_date/symbol)
         │
         ▼
AWS Glue Data Catalog (Glue Crawler → stockpulse_db.sp_processed)
         │
         ├─────────────────────────┐
         ▼                         ▼
Amazon Athena               Amazon Redshift Serverless
(ad-hoc SQL queries)        (analytical warehouse)
         │                         │
         └────────────┬────────────┘
                      ▼
              Grafana Cloud
          (live dashboard, 5 panels)
```

---

## Tech Stack

| Layer | Service | Purpose |
|---|---|---|
| Data Source | Polygon.io REST API | Live/historical stock tick data (free tier) |
| Scheduling | Amazon EventBridge | Cron trigger for Lambda ingester |
| Ingestion | AWS Lambda (Ingester) | Fetch from Polygon.io → push to Kinesis |
| Streaming | Amazon Kinesis Data Streams | Real-time event stream buffer |
| Raw Processing | AWS Lambda (Processor) | Kinesis → Parquet → S3 raw/ |
| Storage (Raw) | Amazon S3 | Raw tick data in Parquet (Snappy compressed) |
| Transformation | AWS Glue PySpark ETL | Raw tick → clean OHLCV aggregation |
| Storage (Processed) | Amazon S3 | Clean OHLCV Parquet files |
| Metadata | AWS Glue Data Catalog + Crawler | Schema registry and table definitions |
| Ad-hoc Query | Amazon Athena | Serverless SQL on S3 |
| Warehouse | Amazon Redshift Serverless | High-performance analytical queries |
| Visualisation | Grafana Cloud (free tier) | Live dashboards |
| Monitoring | CloudWatch + SQS DLQ | Alarms, logs, dead-letter queue |

**Languages:** Python 3.11 (Lambda, Glue), SQL (Athena / Redshift)

---

## Tracked Symbols (MVP)

`AAPL` `MSFT` `GOOGL` `AMZN` `TSLA` `META` `NVDA` `JPM` `V` `JNJ`

---

## Project Structure

```
stockpulse/
├── README.md
├── .gitignore
├── config/
│   └── symbols.json                  # Tracked symbols and config
├── infrastructure/
│   └── setup/
│       └── create_resources.sh       # AWS CLI script — create all resources
├── lambda/
│   ├── ingester/
│   │   ├── lambda_function.py        # Polygon.io → Kinesis
│   │   └── requirements.txt
│   └── processor/
│       ├── lambda_function.py        # Kinesis → S3 raw/ (Parquet)
│       └── requirements.txt
├── glue/
│   └── ohlcv_transform.py           # PySpark ETL: raw → OHLCV
├── sql/
│   ├── redshift_ddl.sql             # CREATE TABLE DDL
│   ├── athena_queries.sql           # Sample validation queries
│   └── redshift_copy.sql           # COPY from S3
├── grafana/
│   └── dashboard.json              # Exported dashboard config
├── scripts/
│   ├── deploy_lambda.sh            # Package + deploy Lambdas
│   ├── upload_glue_script.sh       # Upload Glue script to S3
│   └── run_glue_job.sh             # Trigger Glue job
├── tests/
│   ├── test_ingester.py
│   ├── test_processor.py
│   └── test_glue_transform.py
└── docs/
    └── architecture_diagram.png
```

---

## Setup Guide

### Prerequisites

- AWS account with CLI configured (`aws configure`)
- Polygon.io API key (free tier: [polygon.io](https://polygon.io))
- Python 3.11+
- Docker (for building the PyArrow Lambda Layer)

### Step 1 — Clone and configure

```bash
git clone https://github.com/utkarshsingh1102/stockpulse.git
cd stockpulse
```

### Step 2 — Set your AWS region and account

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Step 3 — Create all AWS resources

```bash
chmod +x infrastructure/setup/create_resources.sh
./infrastructure/setup/create_resources.sh
```

This script creates: S3 bucket, IAM roles, Kinesis stream, SQS DLQ, CloudWatch alarms, EventBridge rule, and Glue database.

### Step 4 — Deploy Lambda functions

```bash
chmod +x scripts/deploy_lambda.sh
POLYGON_API_KEY=your_key_here ./scripts/deploy_lambda.sh
```

### Step 5 — Upload and run Glue ETL

```bash
chmod +x scripts/upload_glue_script.sh scripts/run_glue_job.sh
./scripts/upload_glue_script.sh
./scripts/run_glue_job.sh
```

### Step 6 — Set up Grafana Cloud

1. Create a free account at [grafana.com](https://grafana.com/products/cloud/)
2. Add a JSON API datasource pointing to your API Gateway endpoint (see `infrastructure/setup/create_resources.sh`)
3. Import `grafana/dashboard.json`

---

## Environment Variables

| Variable | Used By | Description |
|---|---|---|
| `POLYGON_API_KEY` | Lambda Ingester | Polygon.io API key |
| `KINESIS_STREAM_NAME` | Lambda Ingester | `stockpulse-stream` |
| `SYMBOLS` | Lambda Ingester | Comma-separated symbol list |
| `S3_BUCKET` | Lambda Processor | `stockpulse-data` |
| `S3_INPUT_PATH` | Glue ETL | `s3://stockpulse-data/raw/` |
| `S3_OUTPUT_PATH` | Glue ETL | `s3://stockpulse-data/processed/` |

---

## Design Decisions

| Decision | Why | Tradeoff |
|---|---|---|
| Kinesis over SQS | Ordered stream with replay capability | Higher cost than SQS ($0.015/shard-hr) |
| Parquet over JSON | 10x compression + fast columnar reads | Requires PyArrow Lambda Layer |
| Glue PySpark for transforms | Handles window functions, scales with data | ~2 min cold start, DPU cost |
| Redshift Serverless | Pay-per-query, no idle cluster | Slightly higher query latency than provisioned |
| Athena + Redshift both | Shows both skills; Athena for ad-hoc, Redshift for dashboards | Two engines to maintain |
| Snapshot endpoint for ingestion | Fetches all 10 symbols in 1 API call → respects 5 req/min free tier | Less granular than per-symbol calls |
| Symbol as Kinesis partition key | Ordering per symbol, future multi-shard scaling | Potential hot shard (unlikely for 10 symbols) |
| Snappy compression | Best balance of compression + decompression speed | Less compression than gzip |

---

## Cost Estimate (Monthly)

| Service | Est. Cost | Notes |
|---|---|---|
| Lambda | ~$0 | Well within free tier |
| Kinesis | ~$15 | 1 shard × $0.015/hr × 730 hrs |
| S3 | ~$1–3 | Small data volume |
| Glue ETL | ~$5–10 | 2 DPU × $0.44/DPU-hr |
| Athena | ~$0–2 | $5/TB scanned |
| Redshift Serverless | ~$10–20 | 8 RPU minimum |
| Grafana Cloud | $0 | Free tier |
| **Total** | **~$30–50/month** | Pause Kinesis + EventBridge when not developing |

**Cost tip:** Delete the Kinesis stream and disable the EventBridge rule when not actively testing — shards cost $0.015/hr even idle.

---

## License

MIT
