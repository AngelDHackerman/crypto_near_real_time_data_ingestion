"""
Silver -> Gold: the 1-minute feature table.  roadmap.md Phase 7.

This is the table Phase 8 trains on and Phase 10 serves from. It is the first
Gold dataset built on the Binance series rather than on CoinMarketCap
snapshots, and it is where data_sources.md section 10's "Gold IS the join"
finally becomes a thing that exists.

THE SCHEMA IS LAYERED BY AVAILABILITY, NOT FLATTENED
    data_sources.md section 11 is blunt about this: the free archive gives
    1-minute OHLCV back to 2017, and NOTHING sub-minute before Phase 5. A single
    flat schema over both would be ~90% null in its most interesting columns for
    ~99% of its rows, and a model trained on it learns "the tick features are
    missing" as a proxy for "this row is old".

    So there are three blocks and each row says which of them it actually has:

      core     -- everything derived from 1-minute OHLCV. 2017 -> now, dense.
                  Computed by indicators.sql.
      context  -- CoinMarketCap market cap, dominance and supply, attached by an
                  as-of join. Starts when CMC ingestion starts.
      tick     -- reserved for aggTrade-derived features. NOT computed here;
                  silver/binance/trades exists but has no rows until the
                  wake-up, and a column that is null for every row in the lake
                  is a promise, not a feature. `has_tick_features` is written
                  as FALSE so that the day it becomes true is visible in the
                  data rather than in a commit message.

    `feature_block_version` travels with every row. Phase 8's DoD is a baseline
    metric, and a baseline computed against features whose definition later
    changed is not a baseline. See feature_schema.md.

WHY THE MATHS IS NOT IN THIS FILE
    It is in indicators.sql, executed here and executed by tests/test_indicators.py
    on DuckDB with no Spark. One owner per fact, and the fact is verifiable
    without a cluster. See the header of that file.

THE WARM-UP IS WHAT MAKES A DAILY RUN CHEAP OVER A NINE-YEAR TABLE
    Every window in indicators.sql is time-bounded and the longest spans 1440
    minutes. So computing today's features needs today plus a bounded tail of
    yesterday -- NOT the 133 million rows behind it. The job therefore reads
    [PROCESS_FROM - WARMUP_DAYS, PROCESS_TO], computes over all of it, and
    writes only the rows from PROCESS_FROM onward. The warm-up rows exist to
    fill the windows and are then discarded.

    Get this wrong in the other direction and the bug is silent: without the
    warm-up, the first bar of each day has an empty look-back, so every
    indicator restarts from nothing at midnight and the model sees a daily
    sawtooth that is an artefact of the job's own scheduling. That is the "null
    explosion at series boundaries" in Phase 7's DoD, and the warm-up is the
    answer to it.

    With no PROCESS_FROM the job runs in FULL mode over the whole table, which
    is what the initial backfill needs and what nothing else should use.
"""

import sys

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import Window
from pyspark.sql import functions as F
from pyspark.sql import types as T

from indicator_sql import build_sql  # shipped via --extra-py-files

ARG_KEYS = [
    "JOB_NAME",
    "SILVER_BUCKET",
    "SILVER_PREFIX",
    "SILVER_STREAMING_PREFIX",
    "GOLD_BUCKET",
    "GOLD_MARKET_FEATURES_PREFIX",
    "TRACKED_ASSETS_URI",
    "INDICATORS_SQL_URI",
    "FEATURE_BLOCK_VERSION",
]
OPTIONAL = ("PROCESS_FROM", "PROCESS_TO", "WARMUP_DAYS", "PROCESS_MODE", "PROCESS_DAYS_BACK")

supplied = {a.lstrip("-").split("=")[0] for a in sys.argv}
args = getResolvedOptions(sys.argv, ARG_KEYS + [k for k in OPTIONAL if k in supplied])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.session.timeZone", "UTC")

silver_klines = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_STREAMING_PREFIX'].strip('/')}/klines/"
silver_cmc = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_PREFIX'].strip('/')}/"
gold_path = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_MARKET_FEATURES_PREFIX'].strip('/')}/"

# --- how much of the table this run covers ---------------------------------
#
# Three ways in, and the precedence matters. An explicit PROCESS_FROM always
# wins, because it is what a human types to repair a specific range. Otherwise
# PROCESS_MODE decides: "full" rebuilds everything, which is what the initial
# 2017 load needs and what nothing scheduled should ever do; "incremental" --
# the default the state machine relies on -- covers the last PROCESS_DAYS_BACK
# days.
#
# The window is computed HERE and not in the state machine because Amazon States
# Language has no date arithmetic. Expressing "yesterday" in ASL means string
# surgery on an ISO timestamp; expressing it in Python is one line, and the line
# is next to the warm-up logic it has to agree with.
#
# Two days rather than one is deliberate. The daily run at 00:00 UTC processes a
# day that has just ended, but Firehose buffers for five minutes and the Silver
# job runs before this one in the same execution -- so the final minutes of
# "yesterday" can land after this job has already read them. Re-deriving two
# days costs a few minutes of Spark and closes that race, and dynamic partition
# overwrite makes re-deriving a day idempotent.
process_mode = (args.get("PROCESS_MODE") or "incremental").lower()
process_days_back = int(args.get("PROCESS_DAYS_BACK") or 2)
process_from = args.get("PROCESS_FROM") or None
process_to = args.get("PROCESS_TO") or None

if not process_from and process_mode != "full":
    from datetime import date, timedelta  # noqa: PLC0415

    process_from = (date.today() - timedelta(days=process_days_back)).isoformat()
    print(f"incremental run: PROCESS_FROM={process_from} (last {process_days_back} days)")
elif not process_from:
    print("FULL run: rebuilding every partition. This is the 2017 load, not a scheduled run.")
# Two days covers the 1440-minute window with a full day to spare. It is a
# variable rather than a literal because the day a longer window is added to
# indicators.sql, this is the other half of that change.
warmup_days = int(args.get("WARMUP_DAYS") or 2)

# ---------------------------------------------------------------------------
# The symbol <-> cmc_id bridge, read from the one file that owns it.
#
# Never joined on the ticker symbol. data_sources.md section 6: tickers
# case-shift (XAUt/XAUT), get renamed (RNDR -> RENDER) and get re-issued under a
# new id (MATIC -> POL). The CoinMarketCap id is the only stable key, and
# config/tracked_assets.json is the only place the pairing is written down.
# ---------------------------------------------------------------------------
cfg_bucket, cfg_key = args["TRACKED_ASSETS_URI"][5:].split("/", 1)
s3 = boto3.client("s3")
tracked = __import__("json").loads(s3.get_object(Bucket=cfg_bucket, Key=cfg_key)["Body"].read())

bridge_rows = [
    (a["binance_symbol"], int(a["cmc_id"]), a["symbol"])
    for a in tracked["assets"]
    if a.get("has_stream")
]
bridge = spark.createDataFrame(
    bridge_rows,
    T.StructType(
        [
            T.StructField("symbol", T.StringType()),
            T.StructField("cmc_id", T.IntegerType()),
            T.StructField("asset_symbol", T.StringType()),
        ]
    ),
)

indicators_template = (
    s3.get_object(
        Bucket=args["INDICATORS_SQL_URI"][5:].split("/", 1)[0],
        Key=args["INDICATORS_SQL_URI"][5:].split("/", 1)[1],
    )["Body"]
    .read()
    .decode()
)

# ---------------------------------------------------------------------------
# Read the klines, warm-up included
# ---------------------------------------------------------------------------
bars = spark.read.parquet(silver_klines)

if process_from:
    lower = F.date_sub(F.to_date(F.lit(process_from)), warmup_days)
    bars = bars.filter(F.col("dt") >= lower)
if process_to:
    bars = bars.filter(F.col("dt") <= F.to_date(F.lit(process_to)))

# One bar per (symbol, minute), across BOTH sources. The overlap window is real:
# the archive can be re-downloaded for months the stream already covered, which
# is exactly what the DoD's field-by-field comparison needs. Here, though, the
# feature table must have one row per minute, so the stream wins where both
# exist -- it is the series that continues into the present, and preferring it
# means the boundary between halves is not also a switch in provenance.
bars = (
    bars.withColumn(
        "_rn",
        F.row_number().over(
            Window.partitionBy("symbol", "event_time_utc").orderBy(
                F.when(F.col("source") == "stream", 0).otherwise(1)
            )
        ),
    )
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)

bars.createOrReplaceTempView("bars")
features = spark.sql(build_sql(indicators_template, "bars", dialect="spark"))

# ---------------------------------------------------------------------------
# The as-of join: attach the most recent CoinMarketCap snapshot at or before
# each bar.  data_sources.md section 10.
#
# BACKWARD, NEVER FORWARD. Attaching a snapshot from the future is look-ahead
# leakage, and its signature is a backtest that looks excellent and a live
# model that does not. The whole mechanism below exists to make the direction
# structural rather than a filter someone can forget.
# ---------------------------------------------------------------------------
features = features.join(F.broadcast(bridge), on="symbol", how="left")

try:
    cmc = spark.read.parquet(silver_cmc)
    has_cmc = True
except Exception:  # noqa: BLE001
    # No CoinMarketCap data yet is the NORMAL state before the wake-up: the
    # extractor's schedule is disabled, so silver/cmc/ has never been written.
    # The context block is then null for every row and `has_context_features`
    # says so, which is honest. This is the one read allowed to be absent --
    # a missing klines path is a real failure and is deliberately not caught.
    has_cmc = False

if has_cmc:
    ctx = (
        cmc.select(
            F.col("asset_id").cast(T.IntegerType()).alias("cmc_id"),
            F.col("event_time_utc").alias("_ts"),
            F.col("price_usd").alias("price_cmc"),
            F.col("market_cap"),
            F.col("market_cap_dominance"),
            F.col("circulating_supply"),
        )
        .filter(F.col("cmc_id").isNotNull() & F.col("_ts").isNotNull())
        .withColumn("_is_bar", F.lit(False))
        .withColumn("_cmc_time", F.col("_ts"))
    )

    left = features.withColumn("_ts", F.col("event_time_utc")).withColumn("_is_bar", F.lit(True))
    merged = left.unionByName(ctx, allowMissingColumns=True)

    # Ordering by (_ts, _is_bar) puts a snapshot stamped at exactly the bar's
    # minute BEFORE the bar, because false sorts before true. That is what makes
    # the join "<= t" rather than "< t" -- an hourly snapshot landing on the
    # minute is observable at that minute, and dropping it would quietly widen
    # every staleness measurement by an hour.
    w = (
        Window.partitionBy("cmc_id")
        .orderBy("_ts", "_is_bar")
        .rowsBetween(Window.unboundedPreceding, Window.currentRow)
    )
    for col in ("price_cmc", "market_cap", "market_cap_dominance", "circulating_supply", "_cmc_time"):
        merged = merged.withColumn(col, F.last(col, ignorenulls=True).over(w))

    features = merged.filter(F.col("_is_bar")).drop("_is_bar", "_ts")
else:
    for col, typ in (
        ("price_cmc", T.DoubleType()),
        ("market_cap", T.DoubleType()),
        ("market_cap_dominance", T.DoubleType()),
        ("circulating_supply", T.DoubleType()),
        ("_cmc_time", T.TimestampType()),
    ):
        features = features.withColumn(col, F.lit(None).cast(typ))

features = (
    features.withColumn(
        "cmc_snapshot_age_seconds",
        F.when(
            F.col("_cmc_time").isNotNull(),
            F.unix_timestamp("event_time_utc") - F.unix_timestamp("_cmc_time"),
        ),
    )
    # Staleness is a COLUMN, not a silence (data_sources.md section 10). Three
    # hours is three missed hourly runs. A CoinMarketCap outage must not present
    # itself as a frozen market cap that looks like live data -- which is
    # precisely what a forward-fill with no age beside it would do.
    .withColumn(
        "cmc_stale",
        F.when(F.col("_cmc_time").isNull(), F.lit(None).cast(T.BooleanType())).otherwise(
            F.col("cmc_snapshot_age_seconds") > 3 * 3600
        ),
    )
    # The two prices never merge into one column, and their difference is a
    # feature: CoinMarketCap's price is a cross-exchange aggregate, Binance's is
    # one venue's execution. The gap between them IS single-venue dislocation,
    # measured. Computed only where the snapshot is fresh -- a divergence
    # against a three-hour-old aggregate measures the clock, not the market.
    .withColumn(
        "price_divergence_bps",
        F.when(
            (F.col("price_cmc") > 0) & (~F.coalesce(F.col("cmc_stale"), F.lit(True))),
            (F.col("close") - F.col("price_cmc")) / F.col("price_cmc") * 10000,
        ),
    )
    .drop("_cmc_time")
    .withColumn("has_context_features", F.col("price_cmc").isNotNull())
    .withColumn("has_tick_features", F.lit(False))
    .withColumn("feature_block_version", F.lit(args["FEATURE_BLOCK_VERSION"]))
    .withColumn("dt", F.to_date("event_time_utc"))
)

if process_from:
    # Drop the warm-up. Those rows were read only to fill the windows; writing
    # them would re-emit days that are already correct, and with dynamic
    # overwrite it would do so from a shorter look-back than they were first
    # computed with -- making a re-run change history.
    features = features.filter(F.col("dt") >= F.to_date(F.lit(process_from)))

(
    features.repartition("dt", "symbol")
    .write.mode("overwrite")
    .option("maxRecordsPerFile", 2_000_000)
    .partitionBy("dt", "symbol")
    .parquet(gold_path)
)

job.commit()
