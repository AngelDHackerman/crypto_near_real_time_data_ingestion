"""
Inference Lambda: recent bars -> features -> endpoint -> a scored signal.
roadmap.md Phase 10.

The shape is deliberately boring. All the judgement is in feature_request.py,
which has tests; this reads S3, calls an endpoint and reports timings.

WHY THE OBJECTS ARE DOWNLOADED RATHER THAN READ OVER httpfs
    DuckDB can read Parquet straight from S3, but only after loading the httpfs
    extension -- which it fetches from the internet on first use. A Lambda that
    downloads a binary extension at cold start is a Lambda that fails when
    something unrelated to this project changes, in a way that looks like an
    intermittent timeout. boto3 is already in the runtime and /tmp is already
    there; the objects are a couple of megabytes.

THE TIMING BREAKDOWN IS PART OF THE RESPONSE, NOT A LOG LINE
    Phase 9's promotion rule has a latency gate, and Phase 13 turns it on. A
    gate needs a measurement, and a measurement that only exists in a log is one
    nobody can threshold on. Each stage is reported separately because they fail
    differently: S3 slowness is a partition problem, feature slowness is a
    window problem, endpoint slowness is a model problem.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta, timezone

import boto3
import duckdb

from feature_request import InsufficientHistory, latest_feature_row

SILVER_BUCKET = os.environ["SILVER_BUCKET"]
SILVER_KLINES_PREFIX = os.environ["SILVER_KLINES_PREFIX"]
ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]
INDICATORS_SQL_KEY = os.environ["INDICATORS_SQL_KEY"]
FEATURE_COLUMNS_KEY = os.environ["FEATURE_COLUMNS_KEY"]
ENDPOINT_NAME = os.environ.get("ENDPOINT_NAME", "")
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "50"))

s3 = boto3.client("s3")
runtime = boto3.client("sagemaker-runtime")

# Cached across invocations on a warm container. Both change only on a deploy,
# and re-fetching them per request would add two S3 round trips to a latency
# budget the promotion gate is measured against.
_cache: dict = {}


def _load_config():
    if "template" not in _cache:
        _cache["template"] = s3.get_object(Bucket=ARTIFACTS_BUCKET, Key=INDICATORS_SQL_KEY)["Body"].read().decode()
        manifest = json.loads(s3.get_object(Bucket=ARTIFACTS_BUCKET, Key=FEATURE_COLUMNS_KEY)["Body"].read())
        _cache["features"] = manifest["features"]
        _cache["feature_block_version"] = manifest.get("feature_block_version", "unknown")
    return _cache


def _recent_keys(now=None):
    """List the Silver klines objects covering the look-back window.

    Listed by PARTITION rather than by listing the prefix and sorting: the table
    holds nine years of hours, and a full listing to find the newest 50 would be
    thousands of API calls to discard almost all of them.

    source=stream only. The backfill covers history, not the last two hours, and
    including it would double the objects fetched to add nothing.
    """
    now = now or datetime.now(timezone.utc)
    keys = []
    for back in range(LOOKBACK_HOURS):
        moment = now - timedelta(hours=back)
        prefix = (
            f"{SILVER_KLINES_PREFIX}/source=stream/"
            f"dt={moment:%Y-%m-%d}/hour={moment:%H}/"
        )
        page = s3.list_objects_v2(Bucket=SILVER_BUCKET, Prefix=prefix)
        keys.extend(o["Key"] for o in page.get("Contents", []) if o["Key"].endswith(".parquet"))
    return keys


def handler(event, _context=None):
    started = time.perf_counter()
    symbol = (event or {}).get("symbol", "")
    cfg = _load_config()

    t0 = time.perf_counter()
    keys = _recent_keys()
    local = []
    for key in keys:
        dest = os.path.join("/tmp", key.replace("/", "_"))
        if not os.path.exists(dest):
            s3.download_file(SILVER_BUCKET, key, dest)
        local.append(dest)
    t_fetch = time.perf_counter() - t0

    con = duckdb.connect()
    try:
        t0 = time.perf_counter()
        values, record = latest_feature_row(con, local, symbol, cfg["template"], cfg["features"])
        t_features = time.perf_counter() - t0
    except InsufficientHistory as exc:
        # 422, not 500. The service is working; this symbol cannot be scored
        # right now, and a caller retrying will not help. Distinguishing the two
        # is what keeps Phase 11's alarms meaningful.
        return {"statusCode": 422, "body": json.dumps({"symbol": symbol, "error": str(exc)})}
    except ValueError as exc:
        return {"statusCode": 400, "body": json.dumps({"symbol": symbol, "error": str(exc)})}
    finally:
        con.close()

    if not ENDPOINT_NAME:
        # The endpoint is gated off until a model exists. Returning the feature
        # vector is the honest response: everything up to the model works, and
        # saying so is more useful than a 500 that implies it does not.
        return {
            "statusCode": 503,
            "body": json.dumps({
                "symbol": symbol,
                "error": "no endpoint deployed; serving_enabled is false",
                "features_computed": len(values),
                "feature_block_version": cfg["feature_block_version"],
            }),
        }

    t0 = time.perf_counter()
    response = runtime.invoke_endpoint(
        EndpointName=ENDPOINT_NAME,
        ContentType="text/csv",
        Body=",".join(f"{v:.10g}" for v in values).encode(),
    )
    score = float(response["Body"].read().decode().strip().split(",")[0])
    t_endpoint = time.perf_counter() - t0

    return {
        "statusCode": 200,
        "body": json.dumps({
            "symbol": symbol,
            "event_time_utc": str(record["event_time_utc"]),
            "score": score,
            "feature_block_version": cfg["feature_block_version"],
            "latency_ms": {
                "s3_fetch": round(t_fetch * 1000, 1),
                "features": round(t_features * 1000, 1),
                "endpoint": round(t_endpoint * 1000, 1),
                "total": round((time.perf_counter() - started) * 1000, 1),
            },
        }),
    }
