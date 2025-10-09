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