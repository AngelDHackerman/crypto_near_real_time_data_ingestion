import sys
from pyspark.sql import functions as F, Window as W
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# -------- Args --------
ARG_KEYS = [
    "JOB_NAME",
    "GOLD_BUCKET",
    "GOLD_FEATURES_PREFIX",
    "GOLD_ML_PREFIX"
]

args = getResolvedOptions(sys.argv, ARG_KEYS)

# -----------------------------
# Spark / Glue setup
# -----------------------------
sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

# Keep overwrite scoped to touched partitions
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

# Avoid S3 directory markers (_$folder$)
hconf = spark._jsc.hadoopConfiguration()
hconf.set("fs.s3a.create.directory.marker", "false")
hconf.set("fs.s3a.directory.marker.retention", "delete")

# -----------------------------
# Paths
# -----------------------------
gold_features_path = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_FEATURES_PREFIX'].rstrip('/')}/"
gold_ml_path       = f"s3://{args['GOLD_BUCKET']}/{args['GOLD_ML_PREFIX'].rstrip('/')}/"

# -----------------------------
# Read Gold Features Base
# -----------------------------
df = spark.read.parquet(gold_features_path)

# Ensure dt as date (it should already be if written by Spark, but cast just in case)
if dict(df.dtypes).get("dt") != "date":
    df = df.withColumn("dt", F.to_date("dt"))
    
# Minimal columns expected from gold_features_base:
# asset_id (int), dt (date), symbol, name, price_usd, volume_24h, market_cap,
# market_cap_dominance, circulating_supply, max_supply, turnover_24h, etc.

# -----------------------------
# Helper windows / utils
# -----------------------------
w_time = W.partitionBy("asset_id").orderBy("dt")

def log_ret(col_name: str, n: int):
    """log return over n days, using lag(n)."""
    prev = F.lag(F.col(col_name), n).over(w_time)
    return F.when(prev.isNotNull() & (prev != 0), F.log(F.col(col_name) / prev))

def roll_avg(col, n):
    """trailing mean over last n rows excluding current (t-1 … t-n)."""
    return F.avg(col).over(w_time.rowsBetween(-n, -1))

def roll_std(col, n):
    """trailing std over last n rows excluding current (t-1 … t-n)."""
    return F.stddev_samp(col).over(w_time.rowsBetween(-n, -1))

def safe_div(num, den):
    return F.when(den.isNull() | (den == 0), F.lit(None)).otherwise(num / den)

# -----------------------------
# Core Features
# -----------------------------

# Returns (log)
df = (df
    .withColumn("ret_1d",  log_ret("price_usd", 1))
    .withColumn("ret_3d",  log_ret("price_usd", 3))
    .withColumn("ret_7d",  log_ret("price_usd", 7))
    .withColumn("ret_14d", log_ret("price_usd", 14))
    .withColumn("ret_30d", log_ret("price_usd", 30))
)

# SMA ratios (momentum proxy)
df = (df
    .withColumn("sma_5",  roll_avg(F.col("price_usd"), 5))
    .withColumn("sma_20", roll_avg(F.col("price_usd"), 20))
    .withColumn("sma_5_over_20", safe_div(F.col("sma_5"), F.col("sma_20")))
)

# Volatility (stdev of daily log returns)
df = (df
    .withColumn("vol_3d",  roll_std(F.col("ret_1d"), 3))
    .withColumn("vol_7d",  roll_std(F.col("ret_1d"), 7))
    .withColumn("vol_14d", roll_std(F.col("ret_1d"), 14))
    .withColumn("vol_30d", roll_std(F.col("ret_1d"), 30))
)

# Volume features
df = (df
    .withColumn("vol_chg_1d", F.col("volume_24h") - F.lag("volume_24h", 1).over(w_time))
    .withColumn("vol_mean_14", roll_avg(F.col("volume_24h"), 14))
    .withColumn("vol_std_14",  roll_std(F.col("volume_24h"), 14))
    .withColumn("vol_z_14d",   safe_div(F.col("volume_24h") - F.col("vol_mean_14"), F.col("vol_std_14")))
)