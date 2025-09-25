import sys
from pyspark.sql import functions as F, types as T
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from awsglue.dynamicframe import DynamicFrame

args = getResolvedOptions(sys.argv, [
  "JOB_NAME",
  "RAW_BUCKET",
  "RAW_PREFIX",
  "SILVER_BUCKET",
  "SILVER_PREFIX",
  "PARTITION_BY_ASSET"
])

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

# raw_path = f"s3://{}"