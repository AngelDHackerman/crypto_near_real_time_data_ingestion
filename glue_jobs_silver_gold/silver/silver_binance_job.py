"""
Bronze (Binance stream) -> Silver.  roadmap.md Phase 6.

WHY THIS IS A SECOND JOB AND NOT A CHANGE TO silver_glue_job.py
    data_sources.md section 10 settled it: Silver stays SOURCE-SEPARATED, and
    the join happens in Gold. `silver_glue_job.py` parses a CoinMarketCap
    `quotes/latest` document -- a nested `data` map of 50 assets with a
    `quote.USD` block each. A Binance frame shares not one field with it. One
    job reading both would be a chain of `if this shape then` branches whose
    only real effect is that a CoinMarketCap schema change breaks the stream
    too. Two jobs, one per source, is the smaller blast radius.

    It also keeps Phase 6's own contract: the CMC Silver table's output schema
    is UNCHANGED by this phase. Nothing here touches it.

WHAT BRONZE LOOKS LIKE ON THE WAY IN
    Firehose writes GZIP objects of concatenated newline-delimited JSON under

        binance/year=YYYY/month=MM/day=DD/hour=HH/

    THOSE PATH PARTS ARE ARRIVAL TIME, NOT EVENT TIME, and this job depends on
    that distinction rather than papering over it. Firehose evaluates
    `!{timestamp:...}` against the approximate arrival timestamp of the OLDEST
    record in the object it is writing, so an object under `hour=14/` routinely
    holds events from 13:55 -- the buffer opened then and flushed five minutes
    later. See the decision block in modules/ingestion/streaming.tf.

    So this job NEVER reads the path as time. Event time comes from the
    payload, which is the reason Phase 6 made "the event timestamp travels
    inside the payload" non-negotiable. Incrementality comes from Glue
    bookmarks, which track objects rather than partitions and are therefore
    immune to the skew in the first place.

WHAT IT WRITES: TWO TABLES, NOT ONE
    The stream carries two event types at two different grains, and flattening
    them into one table would mean either nulls in two thirds of every row or a
    fabricated join key:

        silver/binance/trades/dt=YYYY-MM-DD/hour=HH/   -- one row per aggTrade
        silver/binance/klines/dt=YYYY-MM-DD/hour=HH/   -- one row per 1m bar

    Partitioned on EVENT time, `dt` as a date so Athena can project it with a
    single `date` range instead of the four-way integer cross-product the CMC
    table needs.

DEDUPLICATION, AND WHY EACH KEY IS THE ONE IT IS
    At-least-once delivery is the contract on every hop here: the producer
    retries partial PutRecords failures, Kinesis can redeliver, and a Firehose
    retry can land the same record twice. Both keys below are Binance's own
    identifiers, not something derived -- so a duplicate is recognisable even
    if it arrives days apart in a different object.

      trades: (symbol, agg_trade_id). Binance's aggregate trade id is unique
              per symbol forever.
      klines: (symbol, open_time_utc). A 1m bar is re-sent every ~2 seconds
              while it is open, so the SAME bar arrives ~30 times, each time
              more complete. This is not an error path, it is the normal one:
              keep the last, preferring a closed bar (`x: true`) over an open
              one, then the latest event time.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import Window
from pyspark.sql import functions as F
from pyspark.sql import types as T

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "BRONZE_BUCKET",
        "BRONZE_STREAMING_PREFIX",
        "SILVER_BUCKET",
        "SILVER_STREAMING_PREFIX",
    ],
)

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

bronze_path = f"s3://{args['BRONZE_BUCKET']}/{args['BRONZE_STREAMING_PREFIX'].rstrip('/')}/"
silver_root = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_STREAMING_PREFIX'].rstrip('/')}/"

# ---------------------------------------------------------------------------
# The wire format, declared rather than inferred
#
# Inference would work on a good day and is exactly what should not be relied
# on here: the two event types share only four top-level fields, so Spark's
# inferred schema depends on which rows it happens to sample, and a quiet hour
# with no klines would produce a DIFFERENT schema from a busy one. Declaring it
# also means a Binance field that vanishes shows up as a null column instead of
# an AnalysisException halfway through the run.
#
# Field names are Binance's, kept verbatim from the wire. They are terse
# because Binance made them terse; renaming happens on the way out, once.
# ---------------------------------------------------------------------------
KLINE_SCHEMA = T.StructType(
    [
        T.StructField("t", T.LongType()),  # bar open time, ms
        T.StructField("T", T.LongType()),  # bar close time, ms
        T.StructField("s", T.StringType()),  # symbol
        T.StructField("i", T.StringType()),  # interval, "1m"
        T.StructField("f", T.LongType()),  # first trade id in the bar
        T.StructField("L", T.LongType()),  # last trade id in the bar
        T.StructField("o", T.StringType()),  # open   -- Binance sends decimals
        T.StructField("h", T.StringType()),  # high      as STRINGS, on purpose:
        T.StructField("l", T.StringType()),  # low       they are exact there and
        T.StructField("c", T.StringType()),  # close     lossy as JSON floats
        T.StructField("v", T.StringType()),  # base volume
        T.StructField("n", T.LongType()),  # number of trades
        T.StructField("x", T.BooleanType()),  # is this bar closed
        T.StructField("q", T.StringType()),  # quote volume
        T.StructField("V", T.StringType()),  # taker buy base volume
        T.StructField("Q", T.StringType()),  # taker buy quote volume
    ]
)

EVENT_SCHEMA = T.StructType(
    [
        T.StructField("e", T.StringType()),  # event type: aggTrade | kline
        T.StructField("E", T.LongType()),  # event time, ms
        T.StructField("s", T.StringType()),  # symbol
        # --- aggTrade only ---
        T.StructField("a", T.LongType()),  # aggregate trade id
        T.StructField("p", T.StringType()),  # price
        T.StructField("q", T.StringType()),  # quantity
        T.StructField("f", T.LongType()),  # first trade id
        T.StructField("l", T.LongType()),  # last trade id
        T.StructField("T", T.LongType()),  # trade time, ms
        T.StructField("m", T.BooleanType()),  # buyer is the market maker
        # --- kline only ---
        T.StructField("k", KLINE_SCHEMA),
        # --- added by the producer at the edge, not by Binance ---
        T.StructField("_ingested_at", T.LongType()),
        T.StructField("_stream", T.StringType()),
    ]
)


def ms_to_ts(col):
    """Binance milliseconds -> timestamp, without going through a float.

    `from_unixtime(col / 1000)` is the obvious spelling and it is wrong at this
    scale: a 13-digit epoch divided into a double has ~0.1 ms of representable
    precision left, and it drops the sub-second part entirely on the way back.
    `timestamp_millis` is exact.
    """
    return F.timestamp_millis(col)


def dec(col):
    """Binance decimal string -> double.

    Cast from the STRING Binance actually sends, never from an inferred float.
    Prices here span 8 orders of magnitude (BTC at ~1e5, SHIB at ~1e-5), and
    reading them as JSON numbers loses the low digits of the small ones.
    """
    return col.cast(T.DoubleType())


# ---------------------------------------------------------------------------
# Read Bronze
#
# create_dynamic_frame.from_options with a transformation_ctx is what enables
# job bookmarks, and bookmarks are what make this job incremental. They track
# objects Firehose has already delivered, so a re-run picks up only what is
# new -- and, unlike a partition-based watermark, they cannot be fooled by an
# object whose arrival-time path disagrees with its contents.
#
# groupFiles/groupSize coalesce the ~288 objects/day into 128 MB reader splits
# rather than one Spark task per object.
# ---------------------------------------------------------------------------
raw_dyf = glue.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={
        "paths": [bronze_path],
        "recurse": True,
        "groupFiles": "inPartition",
        "groupSize": "134217728",
    },
    format="json",
    transformation_ctx="binance_bronze_ctx",
)

raw = raw_dyf.toDF()

if len(raw.columns) == 0:
    # An empty bookmark window is the normal case for a re-run, not a failure.
    # Committing is what advances the bookmark, so this must not be an exit.
    #
    # There is ONE case this does not cover, and it is deliberately left to
    # fail loudly rather than be swallowed: if the `binance/` prefix has never
    # been written at all, the reader can raise "Path does not exist" instead
    # of handing back an empty frame. That happens exactly once -- on the first
    # scheduled run after the wake-up, if it lands before Firehose's first
    # 5-minute buffer has flushed. A try/except here would also hide a genuine
    # unreadable-Bronze failure every day after that, which is a far worse
    # trade. Re-run the execution; see the wake-up notes in roadmap.md.
    print("no new Bronze objects since the last bookmark; nothing to do")
    job.commit()
    sys.exit(0)

# Re-parse through the declared schema. Round-tripping the row to JSON is the
# same technique silver_glue_job.py uses for the CMC asset struct: it collapses
# whatever choice types the DynamicFrame inferred back into one stable shape.
events = raw.select(
    F.from_json(F.to_json(F.struct([F.col(c) for c in raw.columns])), EVENT_SCHEMA).alias("ev")
).select("ev.*")

# `_ingested_at` is stamped by the producer the moment the frame leaves the
# WebSocket. Its distance from Binance's own event time is the only measure of
# producer lag that survives into the lake -- it cannot be reconstructed later,
# so it is carried into Silver as a column rather than logged and lost.
events = events.withColumn(
    "producer_lag_ms",
    F.when(F.col("_ingested_at").isNotNull() & F.col("E").isNotNull(), F.col("_ingested_at") - F.col("E")),
).withColumn("ingested_at_utc", ms_to_ts(F.col("_ingested_at")))


def write_partitioned(df, prefix: str) -> None:
    """Write one Silver dataset, partitioned on EVENT time.

    dt/hour are derived from event_time_utc, never from the Bronze path. That
    is the whole point of the arrival-vs-event distinction at the top of this
    file: this is where the arrival-time bucketing Firehose imposed is undone.
    """
    out = (
        df.withColumn("dt", F.to_date("event_time_utc"))
        .withColumn("hour", F.date_format("event_time_utc", "HH"))
        .repartition("dt", "hour")
    )
    (
        out.write.mode("append")
        .option("maxRecordsPerFile", 2_000_000)
        .partitionBy("dt", "hour")
        .parquet(f"{silver_root}{prefix}/")
    )


# ---------------------------------------------------------------------------
# aggTrade -> silver/binance/trades
# ---------------------------------------------------------------------------
trades = (
    events.filter(F.col("e") == "aggTrade")
    .select(
        # Trade time, not event time. `T` is when the trade happened on the
        # matching engine; `E` is when Binance got round to telling us. At a
        # one-minute modelling grain they are usually the same millisecond and
        # occasionally are not, and the one that belongs in a price series is
        # the one the market made.
        ms_to_ts(F.col("T")).alias("event_time_utc"),
        F.col("s").alias("symbol"),
        F.col("a").alias("agg_trade_id"),
        dec(F.col("p")).alias("price"),
        dec(F.col("q")).alias("quantity"),
        F.col("f").alias("first_trade_id"),
        F.col("l").alias("last_trade_id"),
        # Binance's `m` reads backwards to most people: true means the BUYER
        # sat on the book and the aggressor was a SELLER. Renamed to say so.
        F.col("m").alias("is_buyer_maker"),
        ms_to_ts(F.col("E")).alias("exchange_event_time_utc"),
        F.col("ingested_at_utc"),
        F.col("producer_lag_ms"),
    )
    .withColumn("notional", F.col("price") * F.col("quantity"))
    .withColumn("source", F.lit("binance"))
    .filter(F.col("event_time_utc").isNotNull() & F.col("symbol").isNotNull() & F.col("agg_trade_id").isNotNull())
    # A zero or negative price is not a cheap asset, it is a corrupt frame.
    .filter(F.col("price") > 0)
)

trades_dedup = (
    trades.withColumn(
        "_rn",
        F.row_number().over(
            Window.partitionBy("symbol", "agg_trade_id").orderBy(F.col("ingested_at_utc").desc_nulls_last())
        ),
    )
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)

write_partitioned(trades_dedup, "trades")

# ---------------------------------------------------------------------------
# kline_1m -> silver/binance/klines
#
# This is the table Phase 7 stitches the free 2017 archive onto: the archive
# rows and these rows are the same twelve fields from the same exchange, so the
# column names below are chosen to match the archive's, not Binance's wire
# abbreviations.
# ---------------------------------------------------------------------------
klines = (
    events.filter(F.col("e") == "kline")
    .select(
        # The bar's OPEN time is its identity -- it is what the archive keys on
        # and what a 1-minute grid joins on. Using the event time instead would
        # give every re-send of the same bar a different timestamp.
        ms_to_ts(F.col("k.t")).alias("event_time_utc"),
        ms_to_ts(F.col("k.T")).alias("close_time_utc"),
        F.col("k.s").alias("symbol"),
        F.col("k.i").alias("bar_interval"),
        dec(F.col("k.o")).alias("open"),
        dec(F.col("k.h")).alias("high"),
        dec(F.col("k.l")).alias("low"),
        dec(F.col("k.c")).alias("close"),
        dec(F.col("k.v")).alias("volume"),
        dec(F.col("k.q")).alias("quote_volume"),
        dec(F.col("k.V")).alias("taker_buy_base_volume"),
        dec(F.col("k.Q")).alias("taker_buy_quote_volume"),
        F.col("k.n").alias("trade_count"),
        F.col("k.f").alias("first_trade_id"),
        F.col("k.L").alias("last_trade_id"),
        # Carried, not filtered on. An unclosed bar is a partial bar, and
        # dropping it here would silently lose the final minute of every run;
        # dedup below prefers the closed version once it arrives, and Phase 7
        # can still see which rows were provisional.
        F.col("k.x").alias("is_closed"),
        ms_to_ts(F.col("E")).alias("exchange_event_time_utc"),
        F.col("ingested_at_utc"),
        F.col("producer_lag_ms"),
    )
    # "stream", not "binance", and the difference is deliberate. Phase 7 stitches
    # the 2017 archive onto this table and requires a `source in {backfill,
    # stream}` column to tell the two halves apart on the overlap window. Both
    # halves come from Binance, so "binance" would carry no information here --
    # whereas on the trades table above, where no archive exists to stitch,
    # naming the exchange is the only thing the column can usefully say.
    .withColumn("source", F.lit("stream"))
    .filter(F.col("event_time_utc").isNotNull() & F.col("symbol").isNotNull())
    .filter(F.col("close") > 0)
)

klines_dedup = (
    klines.withColumn(
        "_rn",
        F.row_number().over(
            Window.partitionBy("symbol", "event_time_utc").orderBy(
                # Closed beats open, then latest wins. Ordering on event time
                # alone would be a coin flip between the closed bar and an open
                # one stamped in the same millisecond.
                F.col("is_closed").desc_nulls_last(),
                F.col("exchange_event_time_utc").desc_nulls_last(),
                F.col("ingested_at_utc").desc_nulls_last(),
            )
        ),
    )
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)

write_partitioned(klines_dedup, "klines")

job.commit()
