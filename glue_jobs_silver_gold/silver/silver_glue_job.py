import sys
from pyspark.sql import functions as F, types as T
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from awsglue.dynamicframe import DynamicFrame
from pyspark.sql import Window
from pyspark.sql.functions import sha2, concat_ws

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

raw_path = f"s3://{args['RAW_BUCKET']}/{args['RAW_PREFIX'].rstrip('/')}/"

raw_dyf = glue.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={
        "paths": [raw_path],
        "recurse": True,
        "groupFiles": "inPartition",
        "groupSize": "134217728" # 128MB
    },
    format="json",
    transformation_ctx="raw_dyf_ctx"
)

df = raw_dyf.toDF()

# Estructura típica: status.timestamp y data[] con assets
df = (df
      .withColumn("status_ts", F.to_timestamp(F.col("status.timestamp")))
      .withColumn("asset", F.explode("data")))

# time preferido: quote.USD.last_updated si existe; fallback a status_ts
event_ts = F.coalesce(
    F.to_timestamp(F.col("asset.quote.USD.last_updated")),
    F.col("status_ts")
)

df_flat = (
  df.select(
    event_ts.alias("event_time_utc"),
    
    F.col("asset.id").cast(T.IntegerType()).alias("asset_id"),
    F.col("asset.symbol").alias("symbol"),
    F.col("asset.name").alias("name"),
    
    F.col("asset.cmc_rank").cast(T.IntegerType()).alias("cmc_rank"),
    F.col("asset.circulating_supply").cast(T.DoubleType()).alias("circulating_supply"),
    F.col("asset.max_supply").cast(T.DoubleType()).alias("max_supply"),
    
    F.col("asset.quote.USD.price").cast(T.DoubleType()).alias("price_usd"),
    F.col("asset.quote.USD.volume_24h").cast(T.DoubleType()).alias("volume_24h"),
    F.col("asset.quote.USD.volume_change_24h").cast(T.DoubleType()).alias("volume_change_24h"),
    F.col("asset.quote.USD.percent_change_1h").cast(T.DoubleType()).alias("pct_change_1h"),
    F.col("asset.quote.USD.percent_change_24h").cast(T.DoubleType()).alias("pct_change_24h"),
    F.col("asset.quote.USD.percent_change_7d").cast(T.DoubleType()).alias("pct_change_7d"),
    F.col("asset.quote.USD.percent_change_30d").cast(T.DoubleType()).alias("pct_change_30d"),
    F.col("asset.quote.USD.percent_change_60d").cast(T.DoubleType()).alias("pct_change_60d"),
    F.col("asset.quote.USD.percent_change_90d").cast(T.DoubleType()).alias("pct_change_90d"),
    F.col("asset.quote.USD.market_cap").cast(T.DoubleType()).alias("market_cap"),
    F.col("asset.quote.USD.market_cap_dominance").cast(T.DoubleType()).alias("market_cap_dominance"),
    F.col("asset.quote.USD.fully_diluted_market_cap").cast(T.DoubleType()).alias("fully_diluted_market_cap"),
    F.col("asset.quote.USD.tvl").cast(T.DoubleType()).alias("tvl")
  )
  .withColumn("source", F.lit("cmc"))
  .withColumn("ingestion_ts_utc", F.current_timestamp())
)

# Sanitizar imposibles y NaN/Inf (Spark puede traerlos)
# Identify numeric columns where isnan makes sense
numeric_types = (T.DoubleType, T.FloatType)
num_cols = [f.name for f in df_flat.schema.fields if isinstance(f.dataType, numeric_types)]

clean = df_flat
# sanitize negatives
clean = (clean
  .withColumn("circulating_supply",
              F.when(F.col("circulating_supply") < 0, None).otherwise(F.col("circulating_supply")))
  .withColumn("max_supply",
              F.when(F.col("max_supply") < 0, None).otherwise(F.col("max_supply")))
)
# sanitize NaN only on numeric columns
for c in num_cols:
    clean = clean.withColumn(c, F.when(F.isnan(F.col(c)), None).otherwise(F.col(c)))

# Dedup por (asset_id, event_time_utc)
z = clean.withColumn("dupe_key", sha2(concat_ws("||", F.col("asset_id"), F.col("event_time_utc").cast("string")), 256))
w = Window.partitionBy("dupe_key").orderBy(F.col("ingestion_ts_utc").desc())
df_dedup = z.withColumn("rn", F.row_number().over(w)).filter("rn=1").drop("rn", "dupe_key")
# Keep only rows with a valid event_time_utc (defensive)
df_dedup = df_dedup.filter(F.col("event_time_utc").isNotNull())


# Particiones
out_path = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_PREFIX'].rstrip('/')}/"
df_out = (df_dedup
          .withColumn("y", F.date_format("event_time_utc","yyyy"))
          .withColumn("m", F.date_format("event_time_utc","MM"))
          .withColumn("d", F.date_format("event_time_utc","dd"))
          .withColumn("h", F.date_format("event_time_utc","HH")))

# Repartition by time partitions to reduce small files and improve scan efficiency
df_out = df_out.repartition("y","m","d","h")

writer = (df_out.write
          .mode("append")
          .option("maxRecordsPerFile", 2_000_000))

if args["PARTITION_BY_ASSET"].lower() in ("1","true","yes"):
    # For query optimization Time partion will go first and then ID
    # Backwards than raw partition, because here we need to optimize Athena queries
    writer = writer.partitionBy("y","m","d","h","asset_id")
else:
    writer = writer.partitionBy("y","m","d","h")
    
writer.parquet(out_path)
job.commit()