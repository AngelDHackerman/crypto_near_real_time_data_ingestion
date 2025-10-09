# gold_ohlc_glue_job.py
import sys
from pyspark.sql import functions as F, types as T, Window
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# GRAIN: minute|hour|day|week|month
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "SILVER_BUCKET",
    "SILVER_PREFIX",
    "GOLD_BUCKET",
    "GOLD_OHLC_PREFIX",
    "GRAIN"
])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

silver_path = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_PREFIX'].rstrip('/')}/"
gold_path   = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_OHLC_PREFIX'].rstrip('/')}/"

grain = args["GRAIN"].lower().strip()
valid = {"minute","hour","day","week","month"}
if grain not in valid:
    raise ValueError(f"GRAIN must be one of {valid}")

# -------- Read Silver --------
df = spark.read.parquet(silver_path)

# Defensive Casts
df = (
    df.withColumn("asset_id",         F.col("asset_id").cast(T.IntegerType()))
      .withColumn("event_time_utc",   F.to_timestamp("event_time_utc"))
      .withColumn("price_usd",        F.col("price_usd").cast(T.DoubleType()))
      .withColumn("market_cap",       F.col("market_cap").cast(T.DoubleType()))
      .withColumn("ingestion_ts_utc", F.to_timestamp("ingestion_ts_utc"))
)

# -------- DEDUP by (asset_id, event_time_utc, price_usd) --------
w_dedupe = (
    Window
    .partitionBy("asset_id","event_time_utc","price_usd")
    .orderBy(F.col("ingestion_ts_utc").desc_nulls_last(), F.col("event_time_utc").desc())
)
df = (df
      .filter(F.col("asset_id").isNotNull() & F.col("event_time_utc").isNotNull() & F.col("price_usd").isNotNull())
      .withColumn("rn_dedup", F.row_number().over(w_dedupe))
      .filter(F.col("rn_dedup") == 1)
      .drop("rn_dedup")
)

# -------- Period based on granularity (Spark: minute/hour/day/week/month) --------
df = df.withColumn("period_start", F.date_trunc(grain, F.col("event_time_utc")))

# -------- Cálculo OHLC --------
w_asc  = Window.partitionBy("asset_id","period_start").orderBy(F.col("event_time_utc").asc())
w_desc = Window.partitionBy("asset_id","period_start").orderBy(F.col("event_time_utc").desc())
w_all  = Window.partitionBy("asset_id","period_start").rowsBetween(Window.unboundedPreceding, Window.unboundedFollowing)

df = (df
      .withColumn("open_price",  F.first("price_usd", ignorenulls=True).over(w_asc))
      .withColumn("close_price", F.first("price_usd", ignorenulls=True).over(w_desc))
      .withColumn("high_price",  F.max("price_usd").over(w_all))
      .withColumn("low_price",   F.min("price_usd").over(w_all))
      .withColumn("open_mcap",   F.first("market_cap", ignorenulls=True).over(w_asc))
      .withColumn("close_mcap",  F.first("market_cap", ignorenulls=True).over(w_desc))
      .withColumn("high_mcap",   F.max("market_cap").over(w_all))
      .withColumn("low_mcap",    F.min("market_cap").over(w_all))
      .withColumn("start_ts",    F.first("event_time_utc", ignorenulls=True).over(w_asc))
      .withColumn("end_ts",      F.first("event_time_utc", ignorenulls=True).over(w_desc))
      .withColumn("n_ticks",     F.count(F.lit(1)).over(w_all))
      .withColumn("valid_ticks", F.sum(F.when(F.col("price_usd").isNotNull(), 1).otherwise(0)).over(w_all))
)

# Reduce to one row by (asset_id, period_start) → we take the last one of the period
df = df.withColumn("rn", F.row_number().over(w_desc)).filter(F.col("rn")==1).drop("rn")