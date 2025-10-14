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
    "GOLD_BUCKET",
    "GOLD_FEATURES_PREFIX",
    "GOLD_OHLC_PREFIX",
    "GRAIN"
    # "PROCESS_FROM",    # YYYY-MM-DD (optional)
    # "PROCESS_TO"       # YYYY-MM-DD (optional)
])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

features_path = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_FEATURES_PREFIX'].rstrip('/')}/"
gold_path   = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_OHLC_PREFIX'].rstrip('/')}/"

grain = args["GRAIN"].lower().strip()
valid = {"hour","day","week","month"}
if grain not in valid:
    raise ValueError(f"GRAIN must be one of {valid}")

# -------- Read Gold Features Base --------
df = spark.read.parquet(features_path)

# ---------- Temporal Window (for controlled backfills) ----------
# if args.get("PROCESS_FROM"):
#     df = df.filter(F.to_date("event_time_utc") >= F.to_date(F.lit(args["PROCESS_FROM"])))
# if args.get("PROCESS_TO"):
#     df = df.filter(F.to_date("event_time_utc") <= F.to_date(F.lit(args["PROCESS_TO"])))

# Defensive Casts
df = (
    df.withColumn("asset_id",         F.col("asset_id").cast(T.IntegerType()))
      .withColumn("event_time_utc",   F.to_timestamp("event_time_utc"))
      .withColumn("price_usd",        F.col("price_usd").cast(T.DoubleType()))
      .withColumn("market_cap",       F.col("market_cap").cast(T.DoubleType()))
      .withColumn("ingestion_ts_utc", F.to_timestamp("ingestion_ts_utc"))
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

# -------- Partitioned Output --------
df_out = (df.select(
            "asset_id","period_start","start_ts","end_ts",
            "n_ticks","valid_ticks",
            F.col("open_price").alias("open"),
            F.col("high_price").alias("high"),
            F.col("low_price").alias("low"),
            F.col("close_price").alias("close"),
            F.col("open_mcap").alias("open_market_cap"),
            F.col("high_mcap").alias("high_market_cap"),
            F.col("low_mcap").alias("low_market_cap"),
            F.col("close_mcap").alias("close_market_cap")
          )
          .withColumn("g",  F.lit(grain))
          .withColumn("dt", F.to_date(F.col("period_start")))
)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
(df_out
 .repartition("g","dt","asset_id")
 .write.mode("overwrite")
 .format("parquet")
 .option("compression","snappy")
 .partitionBy("g","dt","asset_id")
 .save(gold_path))

job.commit()