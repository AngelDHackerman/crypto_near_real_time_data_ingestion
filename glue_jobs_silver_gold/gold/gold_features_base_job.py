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

# -------- Deduplication: (asset_id, event_time_utc) -> last by ingestion_ts_utc --------
w = Window.partitionBy("asset_id", "event_time_utc").orderBy(F.col("ingestion_ts_utc").desc_nulls_last())
df = (
    df.withColumn("rk", F.row_number().over(w))
      .filter(F.col("rk") == 1)
      .drop("rk")
)

# -------- Derive recommended partition (simple and efficient) --------
df = df.withColumn("dt", F.to_date("event_time_utc"))  

# -------- Light Derivatives (turnover 24h check, market cap check) --------
df = (
    df
    # Qué % representa el turnover de 24h relativo al free float
    .withColumn("turnover_24h",
                F.when(F.col("circulating_supply") > 0, F.col("volume_24h") / F.col("circulating_supply")))
    # Gap relativo entre market_cap reportado y el calculado por price * circulating_supply
    .withColumn("market_cap_check",
                F.when(F.col("circulating_supply").isNotNull(), F.col("price_usd") * F.col("circulating_supply")))
    .withColumn("market_cap_check_gap_pct",
                F.when((F.col("market_cap").isNotNull()) & (F.col("market_cap") > 0),
                       (F.abs(F.col("market_cap") - F.col("market_cap_check")) / F.col("market_cap")))
                )
)

# -------- Final Selection --------
cols_final = [
    "asset_id",
    "event_time_utc",
    "symbol",
    "name",
    "source",
    "ingestion_ts_utc",
    "price_usd",
    "market_cap",
    "market_cap_dominance",
    "fully_diluted_market_cap",
    "circulating_supply",
    "max_supply",
    "volume_24h",
    "volume_change_24h",
    "pct_change_1h",
    "pct_change_24h",
    "pct_change_7d",
    "pct_change_30d",
    "pct_change_60d",
    "pct_change_90d",
    # light derivatives
    "turnover_24h",
    "market_cap_check_gap_pct"
]

df_out = df.select(*cols_final, "dt", "asset_id")  # dt/asset_id will be used for partitionBy

# -------- Write: Parquet + Snappy + Dynamic Overwrite --------
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

(
    df_out
    .repartition("dt","asset_id")  # controls the number of files per partition
    .write
    .mode("overwrite")             # rewrites only touched partitions
    .format("parquet")
    .option("compression", "snappy")
    .partitionBy("dt","asset_id")
    .save(gold_path)
)

job.commit()
