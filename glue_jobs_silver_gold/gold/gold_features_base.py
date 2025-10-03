import sys
from pyspark.sql import functions as F, types as T, Window
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# -------- Args --------
# PROCESS_FROM: opcional, YYYY-MM-DD para reprocesar desde esa fecha
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "SILVER_BUCKET",
    "SILVER_PREFIX",
    "GOLD_BUCKET",
    "GOLD_FEATURES_PREFIX",
    "PROCESS_FROM"
])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

silver_path = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_PREFIX'].rstrip('/')}/"
gold_path   = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_FEATURES_PREFIX'].rstrip('/')}/"

# -------- Read Silver --------
df = spark.read.parquet(silver_path)

# Procesamiento incremental (opcional)
if args.get("PROCESS_FROM"):
    df = df.filter(F.to_date("event_time_utc") >= F.to_date(F.lit(args["PROCESS_FROM"])))
    
# -------- Explicit Cast --------
df = (
    df
    .withColumn("asset_id",                 F.col("asset_id").cast(T.IntegerType()))
    .withColumn("event_time_utc",           F.to_timestamp("event_time_utc"))
    .withColumn("ingestion_ts_utc",         F.col("ingestion_ts_utc").cast(T.TimestampType()))
    .withColumn("source",                   F.col("source").cast(T.StringType()))
    .withColumn("symbol",                   F.col("symbol").cast(T.StringType()))
    .withColumn("name",                     F.col("name").cast(T.StringType()))
    .withColumn("circulating_supply",       F.col("circulating_supply").cast(T.DoubleType()))
    .withColumn("max_supply",               F.col("max_supply").cast(T.DoubleType()))
    .withColumn("price_usd",                F.col("price_usd").cast(T.DoubleType()))
    .withColumn("volume_24h",               F.col("volume_24h").cast(T.DoubleType()))
    .withColumn("volume_change_24h",        F.col("volume_change_24h").cast(T.DoubleType()))
    .withColumn("pct_change_1h",            F.col("pct_change_1h").cast(T.DoubleType()))
    .withColumn("pct_change_24h",           F.col("pct_change_24h").cast(T.DoubleType()))
    .withColumn("pct_change_7d",            F.col("pct_change_7d").cast(T.DoubleType()))
    .withColumn("pct_change_30d",           F.col("pct_change_30d").cast(T.DoubleType()))
    .withColumn("pct_change_60d",           F.col("pct_change_60d").cast(T.DoubleType()))
    .withColumn("pct_change_90d",           F.col("pct_change_90d").cast(T.DoubleType()))
    .withColumn("market_cap",               F.col("market_cap").cast(T.DoubleType()))
    .withColumn("market_cap_dominance",     F.col("market_cap_dominance").cast(T.DoubleType()))
    .withColumn("fully_diluted_market_cap", F.col("fully_diluted_market_cap").cast(T.DoubleType()))
)

# -------- Minum Quality --------
df = df.filter(
    F.col("event_time_utc").isNotNull() &
    F.col("asset_id").isNotNull() &
    F.col("price_usd").isNotNull() & (F.col("price_usd") > 0)
)

