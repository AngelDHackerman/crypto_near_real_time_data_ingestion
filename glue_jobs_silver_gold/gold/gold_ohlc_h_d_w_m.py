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