# =============================================================================
# Catalog module -- Glue Data Catalog + Athena  (roadmap.md, Phase 3, Phase 6)
#
# The metadata layer over the lake: the two Glue databases, the Silver tables,
# and the Athena workgroup that queries them.
#
# PHASE 6 DELETED THE CRAWLER. Silver now uses partition projection like Gold
# already did, which removes the last thing that needed one. What went with it:
#
#   - aws_glue_crawler.silver_crawler, its IAM role, the inline least-privilege
#     policy and the AWSGlueServiceRole attachment that made that policy moot
#     (it granted glue:* on "*", so the scoping below it never lowered the
#     role's real ceiling -- recorded honestly at the time, deleted now);
#   - four states from the daily state machine (StartCrawler / Wait 180s /
#     GetCrawler / Choice), and with them ~3 minutes of every run;
#   - the CRAWL_NEW_FOLDERS_ONLY immutability trap Phase 2.1 hit, where any
#     change to the crawler's S3 target needed -replace rather than an update.
#
# The two commented-out Gold crawlers went with it, as code rather than as
# comments. They were kept commented because they documented a decision -- Gold
# uses projection, not crawling -- and that decision is now written down here in
# prose, which is where a decision belongs. Commented-out code is the one form
# of documentation that goes stale without ever looking stale.
#
# WHY THE TABLES ARE TERRAFORM RESOURCES AND NOT MORE .sql FILES. Gold's
# projected tables live in sql/athena_projections_*.sql and are run by hand.
# Copying that here would have made Phase 6 a REGRESSION in automation: a
# Terraform-managed crawler that created the Silver table on every run would be
# replaced by a human remembering to run DDL. The crawler was the wrong tool,
# but it was automated, and replacing it with a manual step to win a stylistic
# point is the wrong trade. So Terraform owns the Silver tables outright, and
# migrating Gold's three .sql files to match is in the backlog.
#
# ONE-TIME MIGRATION NOTE. The deleted crawler wrote its table into this same
# database with table_prefix "silver_". Terraform will not adopt an existing
# table, so if one survives in the catalog from before the lake was emptied,
# the first apply fails with AlreadyExistsException. Drop the orphan first:
#     aws glue get-tables --database-name crypto_silver_db --query 'TableList[].Name'
#     aws glue delete-table --database-name crypto_silver_db --name <orphan>
# There is no data behind it -- Phase 2.1 deleted the lake -- so this drops a
# schema, not a dataset.
# =============================================================================

# -----------------------------------------------------------------------------
# Glue databases
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "silver_db" {
  name = "crypto_silver_db"
  tags = var.tags
}

resource "aws_glue_catalog_database" "gold_db" {
  name = "crypto_gold_db"
  tags = var.tags
}

# -----------------------------------------------------------------------------
# Silver tables -- partition projection, no crawler
#
# Partition projection computes partition locations from a formula at query
# time instead of reading them from the catalog. For this lake that is strictly
# better than a crawler on three counts: partitions exist the instant Spark
# writes them rather than after the next crawl, there is no crawl to pay for or
# wait on, and the catalog cannot drift out of step with S3 because it is no
# longer trying to mirror it.
#
# The cost is that the formula is now a contract: if a Glue job ever changes
# how it partitions, the projection here has to change in the same commit or
# queries silently return nothing. That is why each table below sits next to
# the job that writes it in the comments.
# -----------------------------------------------------------------------------
locals {
  parquet_input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
  parquet_output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
  parquet_serde         = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"

  silver_cmc_location            = "s3://${var.silver_bucket_id}/${var.silver_prefix}"
  silver_binance_trades_location = "s3://${var.silver_bucket_id}/${var.silver_streaming_prefix}/trades"
  silver_binance_klines_location = "s3://${var.silver_bucket_id}/${var.silver_streaming_prefix}/klines"
}

# --- CoinMarketCap ------------------------------------------------------------
#
# Written by glue_jobs_silver_gold/silver/silver_glue_job.py, which partitions
# on y/m/d/h as four separate zero-padded strings. That shape predates this
# phase and is deliberately NOT changed here: Phase 6's contract is that the
# CMC Silver output schema is untouched, and partition columns are part of a
# schema.
#
# It does cost something, and the cost is visible right below: four independent
# integer projections mean an unfiltered query asks Athena to enumerate their
# cross-product (10 x 12 x 31 x 24 = 89,280 candidate partitions) instead of
# the single date range the Binance tables get. Any query that filters on y and
# m collapses that to a couple of hundred, which is what real queries do --
# but it is the reason the two new tables below use `dt date` instead.
resource "aws_glue_catalog_table" "silver_cmc" {
  name          = "silver_cmc"
  database_name = aws_glue_catalog_database.silver_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    "projection.y.type"   = "integer"
    "projection.y.range"  = "2026,2035"
    "projection.y.digits" = "4"

    "projection.m.type"   = "integer"
    "projection.m.range"  = "1,12"
    "projection.m.digits" = "2"

    "projection.d.type"   = "integer"
    "projection.d.range"  = "1,31"
    "projection.d.digits" = "2"

    "projection.h.type"   = "integer"
    "projection.h.range"  = "0,23"
    "projection.h.digits" = "2"

    # $${...} escapes Terraform's own interpolation. These braces are read by
    # Athena at query time, not by Terraform at plan time -- without the escape
    # Terraform would try to resolve `y` as a variable and fail.
    "storage.location.template" = "${local.silver_cmc_location}/y=$${y}/m=$${m}/d=$${d}/h=$${h}"
  }

  partition_keys {
    name = "y"
    type = "int"
  }
  partition_keys {
    name = "m"
    type = "int"
  }
  partition_keys {
    name = "d"
    type = "int"
  }
  partition_keys {
    name = "h"
    type = "int"
  }

  storage_descriptor {
    location      = local.silver_cmc_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    columns {
      name = "event_time_utc"
      type = "timestamp"
    }
    columns {
      name = "asset_id"
      type = "int"
    }
    columns {
      name = "symbol"
      type = "string"
    }
    columns {
      name = "name"
      type = "string"
    }
    columns {
      name = "cmc_rank"
      type = "int"
    }
    columns {
      name = "circulating_supply"
      type = "double"
    }
    columns {
      name = "max_supply"
      type = "double"
    }
    columns {
      name = "price_usd"
      type = "double"
    }
    columns {
      name = "volume_24h"
      type = "double"
    }
    columns {
      name = "volume_change_24h"
      type = "double"
    }
    columns {
      name = "pct_change_1h"
      type = "double"
    }
    columns {
      name = "pct_change_24h"
      type = "double"
    }
    columns {
      name = "pct_change_7d"
      type = "double"
    }
    columns {
      name = "pct_change_30d"
      type = "double"
    }
    columns {
      name = "pct_change_60d"
      type = "double"
    }
    columns {
      name = "pct_change_90d"
      type = "double"
    }
    columns {
      name = "market_cap"
      type = "double"
    }
    columns {
      name = "market_cap_dominance"
      type = "double"
    }
    columns {
      name = "fully_diluted_market_cap"
      type = "double"
    }
    columns {
      name = "tvl"
      type = "double"
    }
    columns {
      name = "source"
      type = "string"
    }
    columns {
      name = "ingestion_ts_utc"
      type = "timestamp"
    }
  }
}

# --- Binance stream: aggregate trades -----------------------------------------
#
# Written by glue_jobs_silver_gold/silver/silver_binance_job.py. `dt` and `hour`
# are derived from the EVENT time in the payload, never from Firehose's arrival
# -time Bronze prefix -- so a query on `dt` here means what it says, which is
# not true one layer down. See the decision block in
# modules/ingestion/streaming.tf.
resource "aws_glue_catalog_table" "silver_binance_trades" {
  name          = "silver_binance_trades"
  database_name = aws_glue_catalog_database.silver_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    # NOW as the upper bound rather than a fixed date: the range must never
    # need editing to keep yesterday's data queryable.
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${var.streaming_projection_start_date},NOW"

    "projection.hour.type"   = "integer"
    "projection.hour.range"  = "0,23"
    "projection.hour.digits" = "2"

    "storage.location.template" = "${local.silver_binance_trades_location}/dt=$${dt}/hour=$${hour}"
  }

  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "hour"
    type = "int"
  }

  storage_descriptor {
    location      = local.silver_binance_trades_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    columns {
      name = "event_time_utc"
      type = "timestamp"
    }
    columns {
      name = "symbol"
      type = "string"
    }
    columns {
      name = "agg_trade_id"
      type = "bigint"
    }
    columns {
      name = "price"
      type = "double"
    }
    columns {
      name = "quantity"
      type = "double"
    }
    columns {
      name = "first_trade_id"
      type = "bigint"
    }
    columns {
      name = "last_trade_id"
      type = "bigint"
    }
    columns {
      name = "is_buyer_maker"
      type = "boolean"
    }
    columns {
      name = "exchange_event_time_utc"
      type = "timestamp"
    }
    columns {
      name = "ingested_at_utc"
      type = "timestamp"
    }
    columns {
      name = "producer_lag_ms"
      type = "bigint"
    }
    columns {
      name = "notional"
      type = "double"
    }
    columns {
      name = "source"
      type = "string"
    }
  }
}

# --- Binance stream: 1-minute klines ------------------------------------------
#
# The table Phase 7 stitches the free 2017 archive onto, which is why its column
# names follow the archive's rather than Binance's wire abbreviations, and why
# `source` carries {stream, backfill} rather than the exchange name.
resource "aws_glue_catalog_table" "silver_binance_klines" {
  name          = "silver_binance_klines"
  database_name = aws_glue_catalog_database.silver_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    # Phase 7 backfills to 2017, and a row outside the projected range is
    # invisible rather than an error -- so this bound is the one thing here
    # that Phase 7 MUST widen when it lands.
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${var.streaming_projection_start_date},NOW"

    "projection.hour.type"   = "integer"
    "projection.hour.range"  = "0,23"
    "projection.hour.digits" = "2"

    "storage.location.template" = "${local.silver_binance_klines_location}/dt=$${dt}/hour=$${hour}"
  }

  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "hour"
    type = "int"
  }

  storage_descriptor {
    location      = local.silver_binance_klines_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    columns {
      name = "event_time_utc"
      type = "timestamp"
    }
    columns {
      name = "close_time_utc"
      type = "timestamp"
    }
    columns {
      name = "symbol"
      type = "string"
    }
    columns {
      name = "bar_interval"
      type = "string"
    }
    columns {
      name = "open"
      type = "double"
    }
    columns {
      name = "high"
      type = "double"
    }
    columns {
      name = "low"
      type = "double"
    }
    columns {
      name = "close"
      type = "double"
    }
    columns {
      name = "volume"
      type = "double"
    }
    columns {
      name = "quote_volume"
      type = "double"
    }
    columns {
      name = "taker_buy_base_volume"
      type = "double"
    }
    columns {
      name = "taker_buy_quote_volume"
      type = "double"
    }
    columns {
      name = "trade_count"
      type = "bigint"
    }
    columns {
      name = "first_trade_id"
      type = "bigint"
    }
    columns {
      name = "last_trade_id"
      type = "bigint"
    }
    columns {
      name = "is_closed"
      type = "boolean"
    }
    columns {
      name = "exchange_event_time_utc"
      type = "timestamp"
    }
    columns {
      name = "ingested_at_utc"
      type = "timestamp"
    }
    columns {
      name = "producer_lag_ms"
      type = "bigint"
    }
    columns {
      name = "source"
      type = "string"
    }
  }
}

# -----------------------------------------------------------------------------
# Athena workgroup
# -----------------------------------------------------------------------------
resource "aws_athena_workgroup" "workgroup" {
  name = "${var.project}-wg-${var.environment}"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.artifacts_bucket_id}/${var.athena_results_prefix}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  state = "ENABLED"
  tags  = var.tags
}
