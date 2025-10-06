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