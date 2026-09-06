"""
Gold features -> the labelled training set.  roadmap.md Phase 7 / Phase 8.

WHAT REPLACED WHAT, AND WHY
    This job used to read gold_features_base -- CoinMarketCap snapshots at a
    DAILY grain -- and label `y_up_1d_2pct`, "did the price rise 2% tomorrow".
    That was the right dataset for a pipeline whose only source polled a REST
    API every five minutes. It is the wrong one now, for two reasons that have
    nothing to do with taste:

      1. THE DAILY GRAIN THREW AWAY THE PROJECT. Phase 5 exists to capture
         tick-level Binance data; Phase 7 stitched nine years of 1-minute bars
         onto it. Training on daily CoinMarketCap snapshots would mean the
         streaming half of this system feeds a model that cannot see it.

      2. THE HISTORY WAS WEEKS LONG. CoinMarketCap ingestion started when this
         project did. The Binance archive starts in 2017. Phase 8's baseline
         metric and Phase 13's degradation threshold both need a history to be
         measured against, and only one of these sources has one.

    gold_features_base is NOT deleted and this job no longer reads it. It is
    still the market-context table, still hourly, still the only place market
    cap and dominance live, and the feature job attaches it by an as-of join.

THE TARGET, STATED PRECISELY
    Binary: does the forward log return over LABEL_HORIZON_MIN minutes exceed
    LABEL_THRESHOLD_BPS basis points?

    The threshold is not decoration and it is not a hyperparameter to be tuned
    away. Binance's taker fee is 10 bps a side, so a round trip costs ~20 bps
    before slippage. A label of "the price went up" therefore marks a great many
    moves that would have LOST money, and a model that predicts them perfectly
    is worthless. Labelling "moved enough to have covered its own costs" is the
    smallest change that makes the target mean something. It also makes the
    positive class a minority, which is why Phase 8's baseline metric is PR-AUC
    and not accuracy -- on a class this imbalanced, "always predict no" scores
    well and does nothing.

    This is a technical demonstration, not a trading system: the threshold makes
    the target honest, it does not make the output actionable. roadmap.md says
    so at the top and it stays true here.

WHY THE ROWS ARE SAMPLED AND NOT ALL KEPT
    Consecutive 1-minute rows have labels computed over almost the same forward
    window: at a 60-minute horizon, the labels of two adjacent minutes share 59
    minutes of outcome. They are not independent observations, and treating them
    as such inflates every validation score -- the model gets credit for
    predicting the same event hundreds of times. Sampling on a fixed grid at the
    horizon's own stride makes consecutive retained rows have disjoint label
    windows.

    The grid is anchored to the epoch rather than to each asset's first bar, so
    every asset is sampled at the same wall-clock minutes and a cross-sectional
    row is actually cross-sectional.

WHAT IS DELIBERATELY NOT DONE HERE
    No train/validation split, no scaling, no imputation. Those are modelling
    decisions and they belong to the training job, which is the only place that
    can keep them consistent between fit and inference. This job's contract is
    "rows with features and a label, and no leakage".
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import Window
from pyspark.sql import functions as F
from pyspark.sql import types as T

ARG_KEYS = [
    "JOB_NAME",
    "GOLD_BUCKET",
    "GOLD_MARKET_FEATURES_PREFIX",
    "GOLD_ML_PREFIX",
    "FEATURE_BLOCK_VERSION",
]
OPTIONAL = (
    "PROCESS_FROM",
    "PROCESS_TO",
    "LABEL_HORIZON_MIN",
    "LABEL_THRESHOLD_BPS",
    "SAMPLE_STRIDE_MIN",
    "PROCESS_MODE",
    "PROCESS_DAYS_BACK",
)

supplied = {a.lstrip("-").split("=")[0] for a in sys.argv}
args = getResolvedOptions(sys.argv, ARG_KEYS + [k for k in OPTIONAL if k in supplied])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.session.timeZone", "UTC")

features_path = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_MARKET_FEATURES_PREFIX'].strip('/')}/"
ml_path = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_ML_PREFIX'].strip('/')}/"

horizon = int(args.get("LABEL_HORIZON_MIN") or 60)
threshold_bps = float(args.get("LABEL_THRESHOLD_BPS") or 20)
stride = int(args.get("SAMPLE_STRIDE_MIN") or horizon)
# Same three-way window as the feature job, and the same reasoning -- see its
# header. The days-back default is larger here by exactly the label horizon's
# worth of slack: a row can only be labelled once its forward window has
# elapsed, so the most recent rows the previous run saw were unlabelable and
# have to be revisited.
process_mode = (args.get("PROCESS_MODE") or "incremental").lower()
process_days_back = int(args.get("PROCESS_DAYS_BACK") or 3)
process_from = args.get("PROCESS_FROM") or None
process_to = args.get("PROCESS_TO") or None

if not process_from and process_mode != "full":
    from datetime import date, timedelta  # noqa: PLC0415

    process_from = (date.today() - timedelta(days=process_days_back)).isoformat()
    print(f"incremental run: PROCESS_FROM={process_from} (last {process_days_back} days)")

df = spark.read.parquet(features_path)

# The label looks FORWARD by `horizon` minutes, so a run bounded at PROCESS_TO
# must still read that far past it or the last rows get a truncated outcome.
# Reading one extra day is simpler than reading exactly `horizon` minutes and is
# the same cost at this partition grain.
if process_from:
    df = df.filter(F.col("dt") >= F.to_date(F.lit(process_from)))
if process_to:
    df = df.filter(F.col("dt") <= F.date_add(F.to_date(F.lit(process_to)), 1))

# ---------------------------------------------------------------------------
# The forward window
#
# Time-based, not row-based, for the same reason indicators.sql uses RANGE
# frames: the series is gappy, and `LEAD(close, 60)` across a maintenance halt
# reaches an hour and a half into the future while claiming to be an hour.
# ---------------------------------------------------------------------------
fwd = (
    Window.partitionBy("symbol")
    .orderBy(F.col("event_time_utc").cast("long"))
    .rangeBetween(0, horizon * 60)
)

labelled = (
    df.withColumn("fwd_close", F.last("close", ignorenulls=True).over(fwd))
    .withColumn("fwd_time", F.last("event_time_utc", ignorenulls=True).over(fwd))
    .withColumn(
        "label_span_minutes",
        (F.unix_timestamp("fwd_time") - F.unix_timestamp("event_time_utc")) / 60.0,
    )
    .withColumn(
        "fwd_ret",
        F.when((F.col("close") > 0) & (F.col("fwd_close") > 0), F.log(F.col("fwd_close") / F.col("close"))),
    )
)

# The last rows of the table have no future to look at, and the forward window
# silently returns the row's OWN close there -- a forward return of exactly
# zero, which labels as a confident negative. Requiring the realised span to be
# most of the horizon is what turns that into a null.
#
# 0.8 rather than 1.0 because a real gap inside the window shortens the span
# legitimately; demanding the full horizon would discard every row near a halt.
min_span = horizon * 0.8

labelled = (
    labelled.withColumn("label_is_valid", F.col("label_span_minutes") >= F.lit(min_span))
    .withColumn(
        "y_up",
        F.when(
            F.col("label_is_valid") & F.col("fwd_ret").isNotNull(),
            (F.col("fwd_ret") > F.lit(threshold_bps / 10000.0)).cast(T.IntegerType()),
        ),
    )
    .withColumn("y_fwd_ret", F.when(F.col("label_is_valid"), F.col("fwd_ret")))
)

# ---------------------------------------------------------------------------
# Quality gate and sampling
# ---------------------------------------------------------------------------
sampled = (
    labelled.filter(F.col("y_up").isNotNull())
    # A row whose hour is more than half missing has windows built on too little
    # to mean anything. Dropped explicitly rather than left to arrive as nulls,
    # because a null feature and a feature computed from four bars look the same
    # to a model and only one of them is honest.
    .filter(F.col("bars_in_60m") >= 30)
    # The features that must exist for a row to be usable at all. Listed rather
    # than inferred: `dropna()` over every column would also drop each row whose
    # CoinMarketCap context is missing, which is every row before the wake-up.
    .filter(
        F.col("ret_60m").isNotNull()
        & F.col("rsi_14").isNotNull()
        & F.col("vol_60m").isNotNull()
        & F.col("volume_z_1440m").isNotNull()
    )
    # The disjoint-label grid, anchored to the epoch so every asset lands on the
    # same minutes.
    .filter((F.unix_timestamp("event_time_utc") / 60).cast("long") % stride == 0)
)

out = (
    sampled.withColumn("label_horizon_min", F.lit(horizon))
    .withColumn("label_threshold_bps", F.lit(threshold_bps))
    .withColumn("sample_stride_min", F.lit(stride))
    # The label definition travels with the rows for the same reason the feature
    # version does: Phase 13 compares a challenger against a champion, and a
    # comparison across two different targets is not a comparison.
    .withColumn("label_version", F.lit(f"h{horizon}m_t{int(threshold_bps)}bps"))
    .drop("fwd_close", "fwd_time", "fwd_ret", "label_is_valid")
)

(
    out.repartition("dt", "symbol")
    .write.mode("overwrite")
    .option("maxRecordsPerFile", 1_000_000)
    .partitionBy("dt", "symbol")
    .parquet(ml_path)
)

job.commit()
