# =========================
# Glue Silver Job (v3.3)
# - Compatible con RAW normalizado y RAW histórico
# - Excluye manifests/status
# - Fallbacks robustos (quote.* y root supplies)
# - Dedupe por (asset_id, event_time_utc)
# =========================

import sys
from pyspark.sql import functions as F, types as T
from pyspark.sql import Window
from pyspark.sql.functions import sha2, concat_ws
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# -------------------- Args --------------------
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "RAW_BUCKET",
    "RAW_PREFIX",
    "SILVER_BUCKET",
    "SILVER_PREFIX",
    "PARTITION_BY_ASSET"
])

DEBUG = False  # pon True para diagnósticos

sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

# -------------------- Paths --------------------
raw_path = f"s3://{args['RAW_BUCKET']}/{args['RAW_PREFIX'].rstrip('/')}/"
out_path = f"s3://{args['SILVER_BUCKET']}/{args['SILVER_PREFIX'].rstrip('/')}/"

# -------------------- Read RAW --------------------
raw_dyf = glue.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={
        "paths": [raw_path],
        "recurse": True,
        "groupFiles": "inPartition",
        "groupSize": "134217728",
        "exclusions": ["**/manifests/**", "**/status/**"]
    },
    format="json",
    transformation_ctx="raw_dyf_ctx"
)
df = raw_dyf.toDF()

# Filtro defensivo (por si exclusions no aplica en algún motor)
df = (df
      .withColumn("_path", F.input_file_name())
      .filter(~F.col("_path").rlike(r"/(manifests|status)/")))

if DEBUG:
    print("==== RAW DF SCHEMA ====")
    df.printSchema()
    df.show(5, truncate=False)

# -------------------- Helpers --------------------
def nested_dtype(schema: T.StructType, path: str):
    cur = schema
    for name in path.split("."):
        if isinstance(cur, T.StructType):
            f = next((x for x in cur.fields if x.name == name), None)
            if f is None:
                return None
            cur = f.dataType
        else:
            return None
    return cur

def union_double_path(df_schema: T.StructType, path: str):
    dt = nested_dtype(df_schema, path)
    if dt is None:
        return F.lit(None).cast("double")
    if isinstance(dt, T.StructType):
        exprs = []
        for sub, caster in [("double", None), ("long", "double"), ("int", "double"),
                            ("float", "double"), ("string", "double")]:
            if nested_dtype(df_schema, f"{path}.{sub}") is not None:
                col = F.col(f"{path}.{sub}")
                exprs.append(col if caster is None else col.cast(caster))
        return F.coalesce(*exprs) if exprs else F.lit(None).cast("double")
    return F.col(path).cast("double")

def union_int_path(df_schema: T.StructType, path: str):
    dt = nested_dtype(df_schema, path)
    if dt is None:
        return F.lit(None).cast("int")
    if isinstance(dt, T.StructType):
        exprs = []
        for sub, caster in [("int", None), ("long", "int"), ("double", "int"),
                            ("float", "int"), ("string", "int")]:
            if nested_dtype(df_schema, f"{path}.{sub}") is not None:
                col = F.col(f"{path}.{sub}")
                exprs.append(col if caster is None else col.cast(caster))
        return F.coalesce(*exprs) if exprs else F.lit(None).cast("int")
    return F.col(path).cast("int")

def data_kind(schema_fields: dict) -> str:
    dt = schema_fields.get("data")
    if isinstance(dt, T.ArrayType): return "array"
    if isinstance(dt, T.MapType):   return "map"
    return "none"

# -------------------- Normalización guardada por esquema --------------------
schema_fields = {f.name: f.dataType for f in df.schema.fields}

# status_ts: evita referenciar columnas inexistentes
status_type = schema_fields.get("status")
if isinstance(status_type, T.StructType) and any(ch.name == "timestamp" for ch in status_type.fields):
    df = df.withColumn("status_ts", F.to_timestamp(F.col("status.timestamp")))
else:
    df = df.withColumn("status_ts", F.lit(None).cast("timestamp"))

# data puede ser array/map/none
kind = data_kind(schema_fields)
if kind == "array":
    df = (df
          .withColumn("asset_raw", F.explode_outer(F.col("data")))
          .withColumn("asset_key", F.lit(None).cast("string")))
elif kind == "map":
    kv = F.explode_outer(F.map_entries(F.col("data")))
    df = (df
          .withColumn("kv", kv)
          .withColumn("asset_key", F.col("kv.key").cast("string"))
          .withColumn("asset_raw", F.col("kv.value"))
          .drop("kv"))
else:
    cols_for_asset = [c for c in df.columns if c not in ("status_ts",)]
    df = (df
          .withColumn("asset_raw", F.struct(*[F.col(c) for c in cols_for_asset]))
          .withColumn("asset_key", F.lit(None).cast("string")))

if DEBUG:
    print("==== POST-NORMALIZATION SCHEMA ====")
    df.printSchema()
    df.select("asset_raw", "asset_key", "_path").show(5, truncate=False)

# -------------------- Schema estable para asset (parse a asset_s) --------------------
asset_schema = T.StructType([
    T.StructField("id", T.IntegerType()),
    T.StructField("symbol", T.StringType()),
    T.StructField("name", T.StringType()),
    T.StructField("cmc_rank", T.IntegerType()),
    T.StructField("circulating_supply", T.DoubleType()),
    T.StructField("max_supply", T.DoubleType()),
    T.StructField("last_updated", T.StringType()),
    T.StructField("quote", T.StructType([
        T.StructField("USD", T.StructType([
            T.StructField("price", T.DoubleType()),
            T.StructField("volume_24h", T.DoubleType()),
            T.StructField("volume_change_24h", T.DoubleType()),
            T.StructField("percent_change_1h", T.DoubleType()),
            T.StructField("percent_change_24h", T.DoubleType()),
            T.StructField("percent_change_7d", T.DoubleType()),
            T.StructField("percent_change_30d", T.DoubleType()),
            T.StructField("percent_change_60d", T.DoubleType()),
            T.StructField("percent_change_90d", T.DoubleType()),
            T.StructField("market_cap", T.DoubleType()),
            T.StructField("market_cap_dominance", T.DoubleType()),
            T.StructField("fully_diluted_market_cap", T.DoubleType()),
            T.StructField("tvl", T.DoubleType()),
            T.StructField("last_updated", T.StringType()),
        ]))
    ]))
])
df = df.withColumn("asset_s", F.from_json(F.to_json(F.col("asset_raw")), asset_schema))

# Congela schema para helpers
df_schema = df.schema

# -------------------- Event time (robusto) --------------------
event_ts = F.coalesce(
    F.to_timestamp(F.col("asset_s.quote.USD.last_updated")),
    F.to_timestamp(F.col("asset_s.last_updated")),
    F.to_timestamp(F.col("quote.USD.last_updated")),
    F.to_timestamp(F.col("last_updated")),
    F.to_timestamp(F.col("timestamp")),
    F.when(F.col("ts_epoch").isNotNull(),
           F.from_unixtime((F.col("ts_epoch")/1000.0).cast("double"))).otherwise(None),
    F.col("status_ts")
)

# -------------------- Fallbacks de métricas --------------------
def q(field: str):
    # quote.USD.* con fallbacks en root/asset_raw (union-safe)
    return F.coalesce(
        F.col(f"asset_s.quote.USD.{field}").cast("double"),
        union_double_path(df_schema, f"quote.USD.{field}"),
        union_double_path(df_schema, f"asset_raw.quote.USD.{field}")
    )

def root_double(field: str):
    # para circulating_supply / max_supply (y otros root si quisieras)
    return F.coalesce(
        F.col(f"asset_s.{field}").cast("double"),
        union_double_path(df_schema, field),
        union_double_path(df_schema, f"asset_raw.{field}")
    )

# -------------------- Flatten a Silver --------------------
df_flat = (
    df.select(
        event_ts.alias("event_time_utc"),

        # asset_id: asset_s.id -> root id (union-safe) -> map key
        F.coalesce(
            F.col("asset_s.id"),
            union_int_path(df_schema, "id"),
            F.col("asset_key").cast("int")
        ).alias("asset_id"),

        F.coalesce(F.col("asset_s.symbol"), F.col("symbol")).alias("symbol"),
        F.coalesce(F.col("asset_s.name"),   F.col("name")).alias("name"),

        F.col("asset_s.cmc_rank").cast("int").alias("cmc_rank"),

        # supplies con fallback (cubren RAW nuevo y viejo)
        root_double("circulating_supply").alias("circulating_supply"),
        root_double("max_supply").alias("max_supply"),

        # quote.USD con fallback
        q("price").alias("price_usd"),
        q("volume_24h").alias("volume_24h"),
        q("volume_change_24h").alias("volume_change_24h"),
        q("percent_change_1h").alias("pct_change_1h"),
        q("percent_change_24h").alias("pct_change_24h"),
        q("percent_change_7d").alias("pct_change_7d"),
        q("percent_change_30d").alias("pct_change_30d"),
        q("percent_change_60d").alias("pct_change_60d"),
        q("percent_change_90d").alias("pct_change_90d"),
        q("market_cap").alias("market_cap"),
        q("market_cap_dominance").alias("market_cap_dominance"),
        q("fully_diluted_market_cap").alias("fully_diluted_market_cap"),
        q("tvl").alias("tvl"),
    )
    .withColumn("source", F.lit("cmc"))
    .withColumn("ingestion_ts_utc", F.current_timestamp())
)

if DEBUG:
    print("==== FLAT SAMPLE ====")
    df_flat.show(10, truncate=False)

# -------------------- Sanitización --------------------
clean = (df_flat
         .filter(F.col("event_time_utc").isNotNull())
         .filter(F.col("asset_id").isNotNull() | F.col("symbol").isNotNull() | F.col("name").isNotNull()))

# limpia NaN en numéricos
float_cols = [f.name for f in clean.schema.fields if isinstance(f.dataType, (T.FloatType, T.DoubleType))]
clean = (clean
         .withColumn("circulating_supply", F.when(F.col("circulating_supply") < 0, None).otherwise(F.col("circulating_supply")))
         .withColumn("max_supply",         F.when(F.col("max_supply") < 0, None).otherwise(F.col("max_supply"))))
for c in float_cols:
    clean = clean.withColumn(c, F.when(F.isnan(F.col(c)), None).otherwise(F.col(c)))

# -------------------- De-dup (asset_id, event_time_utc) --------------------
dupe_key = sha2(concat_ws("||",
                          F.col("asset_id").cast("string"),
                          F.col("event_time_utc").cast("string")), 256)
w = Window.partitionBy(dupe_key).orderBy(F.col("ingestion_ts_utc").desc())
df_dedup = (clean
            .withColumn("dupe_key", dupe_key)
            .withColumn("rn", F.row_number().over(w))
            .filter(F.col("rn") == 1)
            .drop("rn", "dupe_key"))

# -------------------- QA opcional --------------------
if DEBUG:
    qa = (df_dedup
          .withColumn("minute", F.date_trunc("minute", F.col("event_time_utc")))
          .groupBy("minute")
          .agg(F.countDistinct("asset_id").alias("distinct_assets"),
               F.sum(F.when(F.col("price_usd").isNull(), 1).otherwise(0)).alias("null_prices"))
          .orderBy("minute"))
    qa.show(60, truncate=False)

# -------------------- Write to Silver (partitioned) --------------------
df_out = (df_dedup
          .withColumn("y", F.date_format("event_time_utc", "yyyy"))
          .withColumn("m", F.date_format("event_time_utc", "MM"))
          .withColumn("d", F.date_format("event_time_utc", "dd"))
          .withColumn("h", F.date_format("event_time_utc", "HH"))
          .repartition("y", "m", "d", "h"))

writer = (df_out.write
          .mode("append")
          .option("maxRecordsPerFile", 2_000_000))

if args["PARTITION_BY_ASSET"].lower() in ("1", "true", "yes"):
    writer = writer.partitionBy("y", "m", "d", "h", "asset_id")
else:
    writer = writer.partitionBy("y", "m", "d", "h")

writer.parquet(out_path)

job.commit()
