# =============================================================================
# Gold tables -- Terraform-owned, partition-projected  (roadmap.md, Phase 7)
#
# THIS CLOSES A BACKLOG ITEM, AND THE ITEM WAS A REAL DEFECT RATHER THAN UNTIDY
# BOOKKEEPING. Until now the Gold catalog lived in three .sql files under sql/
# that a human remembered to run in the Athena console. Phase 6 declined to add
# a fourth, on the grounds that replacing an automated crawler with a manual DDL
# step would be a regression in automation, and left "harmonise Gold" for the
# phase that rewrites the Gold jobs anyway. That is this one.
#
# What the manual files had already drifted into, discovered while migrating:
#
#   - sql/athena_projections_ddl_gold_ohlc.sql pins asset_id to an ENUM of
#     ELEVEN ids: '1,1027,52,825,1839,5426,3408,74,2010,1958,1697'. That was the
#     provisional list from before Phase 4. The universe has been 50 ids since
#     Phase 4 froze it, and BAT (1697) is not among them. A row written for any
#     of the other 40 assets would be INVISIBLE to Athena -- not an error, not a
#     warning, just absent -- and one of the ids listed no longer exists in the
#     project at all.
#
#   - gold_features_base carries 'projection.dt.range'='2025-09-24,NOW' and
#     gold_ohlc '2025-09-01,NOW', two different dates, neither of them related
#     to anything the pipeline does now.
#
#   That is precisely the failure mode partition projection has: a mismatched
#   formula returns nothing rather than failing. It survived because nothing
#   read it while the lake was empty. Generating these from
#   config/tracked_assets.json -- the file that already owns the universe --
#   removes the possibility rather than fixing this instance of it.
#
# The three .sql files are kept as a historical record of the manual era, with a
# header pointing here. They are no longer run.
# =============================================================================

locals {
  # Every projected id/symbol comes from the same list Terraform already reads
  # for the Lambda and the producer. One owner per fact, now extended to the
  # catalog.
  gold_asset_id_values = join(",", [for id in var.tracked_asset_ids : tostring(id)])
  gold_symbol_values   = join(",", var.streamed_symbols)

  gold_features_base_location   = "s3://${var.gold_bucket_id}/${var.gold_features_prefix}"
  gold_ohlc_location            = "s3://${var.gold_bucket_id}/${var.gold_ohlc_prefix}"
  gold_market_features_location = "s3://${var.gold_bucket_id}/${var.gold_market_features_prefix}"
  gold_ml_training_location     = "s3://${var.gold_bucket_id}/${var.gold_ml_prefix}"

  # The date projections start at the archive's own floor rather than at a date
  # someone typed. Binance opened in July 2017 and publishes nothing earlier
  # (data_sources.md section 11), so this is the earliest a row can exist.
  gold_projection_start = var.backfill_projection_start_date

  # --- column lists, declared once and rendered by dynamic blocks ------------
  #
  # Written as ordered lists of objects rather than as ~100 repeated `columns {}`
  # blocks. The Gold ML table is the feature table plus its label columns, and
  # expressing that as concat() rather than as a second copy means the two
  # cannot drift -- which matters because Phase 13 compares models across
  # exactly this boundary.
  market_feature_columns = [
    { name = "event_time_utc", type = "timestamp" },
    { name = "source", type = "string" },
    { name = "open", type = "double" },
    { name = "high", type = "double" },
    { name = "low", type = "double" },
    { name = "close", type = "double" },
    { name = "volume", type = "double" },
    { name = "quote_volume", type = "double" },
    { name = "taker_buy_base_volume", type = "double" },
    { name = "taker_buy_quote_volume", type = "double" },
    { name = "trade_count", type = "bigint" },
    { name = "minutes_since_prev", type = "bigint" },
    { name = "ret_1m", type = "double" },
    { name = "ret_since_prev", type = "double" },
    { name = "ret_15m", type = "double" },
    { name = "ret_60m", type = "double" },
    { name = "ret_240m", type = "double" },
    { name = "ret_1440m", type = "double" },
    { name = "sma_15m", type = "double" },
    { name = "sma_60m", type = "double" },
    { name = "sma_240m", type = "double" },
    { name = "close_over_sma_60m", type = "double" },
    { name = "sma_15m_over_240m", type = "double" },
    { name = "vol_15m", type = "double" },
    { name = "vol_60m", type = "double" },
    { name = "vol_240m", type = "double" },
    { name = "bb_z_60m", type = "double" },
    { name = "rsi_14", type = "double" },
    { name = "true_range", type = "double" },
    { name = "atr_15m", type = "double" },
    { name = "hl_range_pct", type = "double" },
    { name = "volume_z_1440m", type = "double" },
    { name = "trade_count_z_1440m", type = "double" },
    { name = "taker_buy_ratio", type = "double" },
    { name = "taker_buy_ratio_60m", type = "double" },
    { name = "quote_per_trade", type = "double" },
    { name = "bars_in_60m", type = "bigint" },
    { name = "bars_in_1440m", type = "bigint" },
    # --- context block: CoinMarketCap, attached by the as-of join ------------
    { name = "cmc_id", type = "int" },
    { name = "asset_symbol", type = "string" },
    { name = "price_cmc", type = "double" },
    { name = "market_cap", type = "double" },
    { name = "market_cap_dominance", type = "double" },
    { name = "circulating_supply", type = "double" },
    { name = "cmc_snapshot_age_seconds", type = "bigint" },
    { name = "cmc_stale", type = "boolean" },
    { name = "price_divergence_bps", type = "double" },
    # --- which blocks this row actually has ----------------------------------
    { name = "has_context_features", type = "boolean" },
    { name = "has_tick_features", type = "boolean" },
    { name = "feature_block_version", type = "string" },
  ]

  ml_label_columns = [
    { name = "y_up", type = "int" },
    { name = "y_fwd_ret", type = "double" },
    { name = "label_span_minutes", type = "double" },
    { name = "label_horizon_min", type = "int" },
    { name = "label_threshold_bps", type = "double" },
    { name = "sample_stride_min", type = "int" },
    { name = "label_version", type = "string" },
  ]

  gold_features_base_columns = [
    { name = "event_time_utc", type = "timestamp" },
    { name = "symbol", type = "string" },
    { name = "name", type = "string" },
    { name = "source", type = "string" },
    { name = "ingestion_ts_utc", type = "timestamp" },
    { name = "price_usd", type = "double" },
    { name = "market_cap", type = "double" },
    { name = "market_cap_dominance", type = "double" },
    { name = "fully_diluted_market_cap", type = "double" },
    { name = "circulating_supply", type = "double" },
    { name = "max_supply", type = "double" },
    { name = "volume_24h", type = "double" },
    { name = "volume_change_24h", type = "double" },
    { name = "pct_change_1h", type = "double" },
    { name = "pct_change_24h", type = "double" },
    { name = "pct_change_7d", type = "double" },
    { name = "pct_change_30d", type = "double" },
    { name = "pct_change_60d", type = "double" },
    { name = "pct_change_90d", type = "double" },
    { name = "turnover_24h", type = "double" },
    { name = "market_cap_check_gap_pct", type = "double" },
  ]

  gold_ohlc_columns = [
    { name = "period_start", type = "timestamp" },
    { name = "start_ts", type = "timestamp" },
    { name = "end_ts", type = "timestamp" },
    { name = "n_ticks", type = "bigint" },
    { name = "valid_ticks", type = "bigint" },
    { name = "open", type = "double" },
    { name = "high", type = "double" },
    { name = "low", type = "double" },
    { name = "close", type = "double" },
    { name = "open_market_cap", type = "double" },
    { name = "high_market_cap", type = "double" },
    { name = "low_market_cap", type = "double" },
    { name = "close_market_cap", type = "double" },
  ]
}

# -----------------------------------------------------------------------------
# gold_market_features_1m -- the table Phase 8 trains on
#
# Partitioned dt/symbol rather than dt/asset_id. The grain is a Binance TRADING
# PAIR, not a CoinMarketCap asset: BTCUSDT is the thing that has a 1-minute bar,
# and cmc_id is a column attached by the join rather than the row's identity.
# Partitioning on asset_id here would name the row after the source it is
# enriched BY instead of the source it comes FROM.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_market_features" {
  name          = "gold_market_features_1m"
  database_name = aws_glue_catalog_database.gold_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${local.gold_projection_start},NOW"

    # An enum of the 45 streamed pairs, generated from the frozen config. An
    # integer or unbounded projection would make Athena enumerate candidate
    # paths that cannot exist; an enum typed by hand would be the eleven-id
    # mistake this file's header describes, one refactor later.
    "projection.symbol.type"   = "enum"
    "projection.symbol.values" = local.gold_symbol_values

    "storage.location.template" = "${local.gold_market_features_location}/dt=$${dt}/symbol=$${symbol}"
  }

  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "symbol"
    type = "string"
  }

  storage_descriptor {
    location      = local.gold_market_features_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    dynamic "columns" {
      for_each = local.market_feature_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# -----------------------------------------------------------------------------
# gold_ml_training -- the labelled rows, sampled to non-overlapping windows
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_ml_training" {
  name          = "gold_ml_training"
  database_name = aws_glue_catalog_database.gold_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${local.gold_projection_start},NOW"

    "projection.symbol.type"   = "enum"
    "projection.symbol.values" = local.gold_symbol_values

    "storage.location.template" = "${local.gold_ml_training_location}/dt=$${dt}/symbol=$${symbol}"
  }

  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "symbol"
    type = "string"
  }

  storage_descriptor {
    location      = local.gold_ml_training_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    dynamic "columns" {
      for_each = concat(local.market_feature_columns, local.ml_label_columns)
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# -----------------------------------------------------------------------------
# gold_features_base -- unchanged dataset, migrated catalog
#
# The CoinMarketCap market-context table. Phase 7 does not touch the job that
# writes it; it only moves the table definition out of
# sql/athena_projections_gold_features_base.sql and repairs the projection's
# asset_id range on the way, from an unbounded 1..9999 integer to the frozen 50.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_features_base" {
  name          = "gold_features_base"
  database_name = aws_glue_catalog_database.gold_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${var.streaming_projection_start_date},NOW"

    "projection.asset_id.type"   = "enum"
    "projection.asset_id.values" = local.gold_asset_id_values

    "storage.location.template" = "${local.gold_features_base_location}/dt=$${dt}/asset_id=$${asset_id}"
  }

  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "asset_id"
    type = "int"
  }

  storage_descriptor {
    location      = local.gold_features_base_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    dynamic "columns" {
      for_each = local.gold_features_base_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# -----------------------------------------------------------------------------
# gold_ohlc -- one table, four grains, selected by the `g` partition
#
# The four convenience VIEWS the old .sql file created (gold_ohlc_hour, _day,
# _week, _month) are NOT recreated. Each was `SELECT * ... WHERE g='<grain>'`,
# which is what the partition key already expresses, and an Athena view is
# stored as a base64 blob of its own query plan -- so a column added to this
# table silently leaves four views describing a shape that no longer exists.
# `WHERE g = 'day'` is one predicate, it prunes the partition, and it cannot go
# stale.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_ohlc" {
  name          = "gold_ohlc"
  database_name = aws_glue_catalog_database.gold_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    classification       = "parquet"
    "projection.enabled" = "true"

    "projection.g.type"   = "enum"
    "projection.g.values" = "hour,day,week,month"

    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.dt.range"         = "${var.streaming_projection_start_date},NOW"

    "projection.asset_id.type"   = "enum"
    "projection.asset_id.values" = local.gold_asset_id_values

    "storage.location.template" = "${local.gold_ohlc_location}/g=$${g}/dt=$${dt}/asset_id=$${asset_id}"
  }

  partition_keys {
    name = "g"
    type = "string"
  }
  partition_keys {
    name = "dt"
    type = "date"
  }
  partition_keys {
    name = "asset_id"
    type = "int"
  }

  storage_descriptor {
    location      = local.gold_ohlc_location
    input_format  = local.parquet_input_format
    output_format = local.parquet_output_format

    ser_de_info {
      serialization_library = local.parquet_serde
    }

    dynamic "columns" {
      for_each = local.gold_ohlc_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}
