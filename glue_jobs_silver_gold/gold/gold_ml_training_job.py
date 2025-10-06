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