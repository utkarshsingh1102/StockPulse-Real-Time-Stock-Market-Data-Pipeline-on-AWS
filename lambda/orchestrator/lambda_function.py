"""
StockPulse — Orchestrator Lambda
Manages the daily ingestion sequence:
  1. Create Kinesis stream
  2. Wait for stream to become ACTIVE
  3. Invoke ingester Lambda (synchronous — waits for completion)
  4. Wait for processor Lambda to flush records to S3
  5. Delete Kinesis stream

Triggered by: EventBridge cron at 3:45 PM ET (19:45 UTC) Mon-Fri
Total runtime: ~5-7 minutes (ingester ~130s + processor flush ~60s)
Lambda timeout must be set to 600s (10 min).

Error handling:
  - Each step is retried up to MAX_RETRIES times before raising
  - Kinesis stream is always deleted on exit (success or failure)
  - All failures are published to CloudWatch as a custom metric
    so you can set an alarm on it in the AWS console
  - Full error details are printed to CloudWatch Logs
"""

import json
import os
import time
import traceback
import boto3
from botocore.config import Config

KINESIS_STREAM        = os.environ["KINESIS_STREAM"]
INGESTER_FUNCTION     = os.environ["INGESTER_FUNCTION"]
GLUE_JOB_NAME         = os.environ["GLUE_JOB_NAME"]
S3_INPUT_PATH         = os.environ["S3_INPUT_PATH"]
S3_OUTPUT_PATH        = os.environ["S3_OUTPUT_PATH"]
AWS_REGION            = os.environ.get("STACK_REGION", "us-east-1")
PROCESSOR_FLUSH_WAIT  = int(os.environ.get("PROCESSOR_FLUSH_WAIT", "90"))
MAX_RETRIES           = 3
RETRY_DELAY           = 10  # seconds between retries

kinesis        = boto3.client("kinesis",    region_name=AWS_REGION)
lambda_client  = boto3.client("lambda",     region_name=AWS_REGION,
                   config=Config(read_timeout=300, connect_timeout=10,
                                 retries={"max_attempts": 0}))
cloudwatch     = boto3.client("cloudwatch", region_name=AWS_REGION)
glue           = boto3.client("glue",       region_name=AWS_REGION)
s3             = boto3.client("s3",         region_name=AWS_REGION)


def log(msg):
    print(f"[orchestrator] {msg}", flush=True)


def publish_metric(metric_name, value=1):
    """Publish a custom CloudWatch metric under StockPulse/Pipeline namespace."""
    try:
        cloudwatch.put_metric_data(
            Namespace="StockPulse/Pipeline",
            MetricData=[{
                "MetricName": metric_name,
                "Value": value,
                "Unit": "Count",
            }]
        )
    except Exception as e:
        log(f"Warning: could not publish metric {metric_name}: {e}")


def with_retry(fn, label):
    """Run fn() with up to MAX_RETRIES attempts. Raises on final failure."""
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            return fn()
        except Exception as e:
            last_exc = e
            log(f"[{label}] attempt {attempt}/{MAX_RETRIES} failed: {e}")
            if attempt < MAX_RETRIES:
                log(f"[{label}] retrying in {RETRY_DELAY}s...")
                time.sleep(RETRY_DELAY)
    raise RuntimeError(f"[{label}] all {MAX_RETRIES} attempts failed") from last_exc


def create_stream():
    try:
        status = kinesis.describe_stream_summary(
            StreamName=KINESIS_STREAM
        )["StreamDescriptionSummary"]["StreamStatus"]
        log(f"Stream already exists — status={status}")
    except kinesis.exceptions.ResourceNotFoundException:
        log(f"Creating Kinesis stream: {KINESIS_STREAM}")
        kinesis.create_stream(StreamName=KINESIS_STREAM, ShardCount=1)
        kinesis.add_tags_to_stream(
            StreamName=KINESIS_STREAM,
            Tags={"project-name": "StockPulse"}
        )
        log("Stream created.")

    # Wait up to 150s for ACTIVE
    log("Waiting for stream to become ACTIVE...")
    for attempt in range(30):
        status = kinesis.describe_stream_summary(
            StreamName=KINESIS_STREAM
        )["StreamDescriptionSummary"]["StreamStatus"]
        if status == "ACTIVE":
            log("Stream is ACTIVE.")
            return
        log(f"  status={status} — retrying in 5s ({attempt + 1}/30)")
        time.sleep(5)

    raise RuntimeError(f"Stream {KINESIS_STREAM} did not become ACTIVE within 150s.")


def invoke_ingester():
    """Invoke ingester asynchronously and poll CloudWatch Logs for completion."""
    import datetime

    log(f"Invoking ingester Lambda asynchronously: {INGESTER_FUNCTION}")
    before = datetime.datetime.utcnow()

    response = lambda_client.invoke(
        FunctionName=INGESTER_FUNCTION,
        InvocationType="Event",  # async — returns immediately with 202
        LogType="None",
    )
    status_code = response["StatusCode"]
    if status_code != 202:
        raise RuntimeError(f"Ingester async invoke returned HTTP {status_code}")

    log("Ingester invoked — polling for completion (max 300s)...")

    logs_client = boto3.client("logs", region_name=AWS_REGION)
    log_group = "/aws/lambda/stockpulse-ingester"
    start_ms = int(before.timestamp() * 1000)

    for attempt in range(60):  # poll every 5s for up to 300s
        time.sleep(5)
        try:
            response = logs_client.filter_log_events(
                logGroupName=log_group,
                startTime=start_ms,
                filterPattern="REPORT RequestId",
            )
            events = response.get("events", [])
            if events:
                log(f"Ingester completed (detected via CloudWatch Logs after {(attempt+1)*5}s)")
                # Check for error in the same timeframe
                err_response = logs_client.filter_log_events(
                    logGroupName=log_group,
                    startTime=start_ms,
                    filterPattern="ERROR",
                )
                if err_response.get("events"):
                    raise RuntimeError("Ingester Lambda reported errors — check /aws/lambda/stockpulse-ingester logs")
                return
        except logs_client.exceptions.ResourceNotFoundException:
            pass  # log group not created yet — ingester hasn't started

    raise RuntimeError("Ingester did not complete within 300s.")


def has_new_data():
    """Check if raw/ has any files written in the last 2 hours."""
    bucket = S3_INPUT_PATH.replace("s3://", "").split("/")[0]
    prefix = "/".join(S3_INPUT_PATH.replace("s3://", "").split("/")[1:])
    now = time.time()
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            age_seconds = now - obj["LastModified"].timestamp()
            if age_seconds < 7200:  # written within last 2 hours
                log(f"New data found: {obj['Key']} (age={int(age_seconds)}s)")
                return True
    log("No new data found in raw/ — skipping Glue.")
    return False


def trigger_glue():
    log(f"Triggering Glue job: {GLUE_JOB_NAME}")
    response = glue.start_job_run(
        JobName=GLUE_JOB_NAME,
        Arguments={
            "--S3_INPUT_PATH": S3_INPUT_PATH,
            "--S3_OUTPUT_PATH": S3_OUTPUT_PATH,
        }
    )
    run_id = response["JobRunId"]
    log(f"Glue job started — JobRunId={run_id}")
    publish_metric("GlueTriggered")
    return run_id


def delete_stream():
    """Always attempt to delete — non-fatal if it fails."""
    try:
        log(f"Deleting Kinesis stream: {KINESIS_STREAM}")
        kinesis.delete_stream(StreamName=KINESIS_STREAM)
        log("Stream deleted.")
    except kinesis.exceptions.ResourceNotFoundException:
        log("Stream already deleted — nothing to do.")
    except Exception as e:
        log(f"Warning: could not delete stream (will age out naturally): {e}")


def lambda_handler(event, context):
    log("=== StockPulse daily ingestion sequence starting ===")
    success = False

    try:
        # Step 1 & 2: Create Kinesis stream and wait for ACTIVE
        with_retry(create_stream, "create_stream")

        # Step 3: Run ingester synchronously (retried on transient failures)
        with_retry(invoke_ingester, "invoke_ingester")

        # Step 4: Wait for processor to flush records to S3
        log(f"Waiting {PROCESSOR_FLUSH_WAIT}s for processor to flush to S3...")
        time.sleep(PROCESSOR_FLUSH_WAIT)

        # Step 5: Check for new data before triggering Glue
        if has_new_data():
            with_retry(trigger_glue, "trigger_glue")
        else:
            publish_metric("GlueSkipped")
            log("Glue skipped — no new data ingested today.")

        success = True
        publish_metric("OrchestratorSuccess")
        log("=== Ingestion sequence complete ===")
        return {"status": "success"}

    except Exception as e:
        log(f"FATAL ERROR: {e}")
        log(traceback.format_exc())
        publish_metric("OrchestratorFailure")
        # Re-raise so Lambda marks the invocation as failed
        # (CloudWatch Logs will capture the full traceback)
        raise

    finally:
        # Always clean up Kinesis regardless of success or failure
        delete_stream()
        if not success:
            log("Pipeline failed — Glue will still run at 5pm but may find no new data.")
