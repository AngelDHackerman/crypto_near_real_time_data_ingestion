"""
Bronze (Binance archive CSV) -> Silver klines.  roadmap.md Phase 7.

It writes into the SAME dataset the streaming Silver job writes,
`silver/binance/klines/`, because that is the point: the archived monthly file
and the live @kline_1m event are the same twelve fields computed by the same
exchange over the same one-minute bucket (data_sources.md section 11), so 2017
and today belong in one table rather than in two that a query has to UNION.

WHY `source` BECAME A PARTITION KEY IN THIS PHASE
    Phase 6 wrote `source` as a plain column with the value "stream", and said
    in the catalog that Phase 7 would add "backfill" beside it. Carrying that
    out exposed something a column cannot express: this is the first phase with
    TWO WRITERS into one dataset, and both of them write Spark partitions keyed
    on (dt, hour).

    Spark has exactly two write modes here and both are wrong across two
    writers. `append` makes a re-run duplicate every row it already wrote --
    and this job WILL be re-run, because a 133-million-row load gets
    interrupted. `overwrite` with dynamic partition overwrite is idempotent,
    which is what a re-runnable load needs, but it replaces the whole (dt,hour)
    directory -- so a backfill month that overlaps the stream would silently
    delete the streamed rows for those hours.

    Promoting `source` to the first partition key gives each writer its own
    subtree, `source=stream/...` and `source=backfill/...`. Each can then use
    dynamic overwrite safely, because dynamic overwrite replaces only the
    partitions present in the data being written, and neither writer ever
    produces the other's value. It is still one table and `source` is still a
    column to any query. The gain is that "re-run the backfill" and "the
    overlap window has both halves" stop being in tension.

    Done here rather than deferred because the table is EMPTY -- the lake was
    deleted in Phase 2.1 and the project is dormant -- so this costs a schema
    edit and no migration. It is the same reasoning Phase 6 used for the two
    renames: do the ForceNew change at the moment nothing is behind it.

THE TIMESTAMP UNIT IS DETECTED PER ROW, NOT ASSUMED PER FILE
    Binance's archive switched from milliseconds to microseconds at 2025-01
    (verified in the header of bronze/backfill_binance_klines.py). Bronze keeps
    the file as published, so the normalisation happens here.

    It is decided from the VALUE, not from the month. A 1-minute open time in
    milliseconds is 13 digits and stays 13 digits until the year 2286, so the
    magnitude is unambiguous and it keeps working if Binance ever re-publishes
    an old month in the new unit. Deriving it from the partition would encode a
    single 2025 announcement as a permanent assumption about every file.

    The failure mode this prevents is the quiet one: microseconds read as
    milliseconds put January 2025 in the year 56,000, and a partition filter
    then hides those rows rather than reporting them.

THE ALIAS OVERLAP IS DEDUPLICATED, AND IT IS NOT HYPOTHETICAL
    RENDER renamed from RNDRUSDT in 2024-07 and POL from MATICUSDT in 2024-09,
    and in each case BOTH tickers publish a file for the rename month. Both are
    downloaded under the canonical `symbol=` partition, so the same minute
    arrives twice. Dedup keeps the CANONICAL ticker's row where both exist --
    the alias file for a rename month is the truncated one.
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
    "BRONZE_BUCKET",
    "BRONZE_BACKFILL_PREFIX",
    "SILVER_BUCKET",
    "SILVER_STREAMING_PREFIX",
]

supplied = {a.lstrip("-").split("=")[0] for a in sys.argv}
# Both inclusive, YYYY-MM. The archive is 133 million rows; being able to load
# it in slices is what makes a failure cost one month rather than all of them.
optional = [k for k in ("MONTH_FROM", "MONTH_TO") if k in supplied]
args = getResolvedOptions(sys.argv, ARG_KEYS + optional)

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.session.timeZone", "UTC")

bronze_path = f"s3://{args['BRONZE_BUCKET']}/{args['BRONZE_BACKFILL_PREFIX'].strip('/')}/"
silver_klines = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_STREAMING_PREFIX'].strip('/')}/klines/"

# ---------------------------------------------------------------------------
# The archive's twelve columns, declared in order.
#
# Declared and not inferred, for the same reason silver_binance_job.py declares
# the wire schema: inference reads a sample, and the numeric columns here span
# eight orders of magnitude across assets. They are read as STRING and cast
# explicitly below -- Binance writes exact decimals and a CSV inference pass
# would hand them to a double before this job ever sees them.
#
# `ignore` is Binance's own name for the twelfth field. It has been unused for
# years and is read only so the positional schema stays aligned.
# ---------------------------------------------------------------------------
ARCHIVE_SCHEMA = T.StructType(
    [
        T.StructField("open_time", T.StringType()),
        T.StructField("open", T.StringType()),
        T.StructField("high", T.StringType()),
        T.StructField("low", T.StringType()),
        T.StructField("close", T.StringType()),
        T.StructField("volume", T.StringType()),
        T.StructField("close_time", T.StringType()),
        T.StructField("quote_volume", T.StringType()),
        T.StructField("trade_count", T.StringType()),
        T.StructField("taker_buy_base_volume", T.StringType()),
        T.StructField("taker_buy_quote_volume", T.StringType()),
        T.StructField("ignore", T.StringType()),
    ]
)

raw = (
    spark.read.option("header", "false")
    .option("mode", "FAILFAST")  # a malformed row is a corrupt download, not a row to drop
    .schema(ARCHIVE_SCHEMA)
    .csv(f"{bronze_path}symbol=*/month=*/")
)

# basePath is not set, so Spark reads `symbol` and `month` off the path as
# partition columns. `symbol` is the CANONICAL pair; the alias that actually
# supplied the month is in the file name, which is deliberate (see the backfill
# job's header) but is not needed as a column here.
if "MONTH_FROM" in args and args["MONTH_FROM"]:
    raw = raw.filter(F.col("month") >= F.lit(args["MONTH_FROM"]))
if "MONTH_TO" in args and args["MONTH_TO"]:
    raw = raw.filter(F.col("month") <= F.lit(args["MONTH_TO"]))


def epoch_to_ts(col):
    """Binance epoch integer -> timestamp, normalising ms and us in one place.

    The cast to decimal(20,0) rather than long is not decoration: a microsecond
    close time is 16 digits, which is inside long's range but outside the exact
    range of a double, and Spark will happily route a string through a double if
    a later expression gives it the chance.
    """
    v = col.cast(T.DecimalType(20, 0))
    micros = F.when(v >= F.lit(1_000_000_000_000_000), v).otherwise(v * 1000)
    return F.timestamp_micros(micros.cast(T.LongType()))


def dec(col):
    return col.cast(T.DoubleType())


klines = (
    raw.select(
        epoch_to_ts(F.col("open_time")).alias("event_time_utc"),
        epoch_to_ts(F.col("close_time")).alias("close_time_utc"),
        F.col("symbol").alias("symbol"),
        F.lit("1m").alias("bar_interval"),
        dec(F.col("open")).alias("open"),
        dec(F.col("high")).alias("high"),
        dec(F.col("low")).alias("low"),
        dec(F.col("close")).alias("close"),
        dec(F.col("volume")).alias("volume"),
        dec(F.col("quote_volume")).alias("quote_volume"),
        dec(F.col("taker_buy_base_volume")).alias("taker_buy_base_volume"),
        dec(F.col("taker_buy_quote_volume")).alias("taker_buy_quote_volume"),
        F.col("trade_count").cast(T.LongType()).alias("trade_count"),
        # The archive does not carry trade ids. They are NULL rather than 0:
        # a zero here would be a trade id, and a reader cannot tell a real one
        # from a placeholder.
        F.lit(None).cast(T.LongType()).alias("first_trade_id"),
        F.lit(None).cast(T.LongType()).alias("last_trade_id"),
        # Every archived bar is final by construction -- the month is closed.
        F.lit(True).alias("is_closed"),
        # Three columns that only a live stream can produce. Null, not zero, for
        # the same reason as the trade ids: a producer lag of 0 ms is a claim,
        # and this row never went through a producer.
        F.lit(None).cast(T.TimestampType()).alias("exchange_event_time_utc"),
        F.lit(None).cast(T.TimestampType()).alias("ingested_at_utc"),
        F.lit(None).cast(T.LongType()).alias("producer_lag_ms"),
        F.lit("backfill").alias("source"),
        F.col("month"),
    )
    .filter(F.col("event_time_utc").isNotNull() & F.col("symbol").isNotNull())
    # A zero or negative close is a corrupt row, not a cheap asset. Same guard
    # the streaming job applies, and it belongs on both paths or neither.
    .filter(F.col("close") > 0)
)

# The rename months, where the canonical and the alias file both cover the same
# minute. Keeping the canonical is not arbitrary: for a rename month the alias
# file stops mid-month and the canonical one starts mid-month, so whichever row
# exists in only one of them survives either way, and where both exist the
# canonical is the one that continues.
klines = (
    klines.withColumn(
        "_rn",
        F.row_number().over(
            Window.partitionBy("symbol", "event_time_utc").orderBy(F.col("trade_count").desc_nulls_last())
        ),
    )
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)

out = (
    klines.withColumn("dt", F.to_date("event_time_utc"))
    .withColumn("hour", F.date_format("event_time_utc", "HH"))
    .drop("month")
)

# Dynamic overwrite, scoped by the source= partition. Re-running this job for a
# month range replaces exactly those (source=backfill, dt, hour) directories and
# cannot touch source=stream. That is what makes an interrupted 4.4 GB load safe
# to simply run again.
(
    out.repartition("dt", "symbol")
    .write.mode("overwrite")
    .option("maxRecordsPerFile", 2_000_000)
    .partitionBy("source", "dt", "hour")
    .parquet(silver_klines)
)

job.commit()
