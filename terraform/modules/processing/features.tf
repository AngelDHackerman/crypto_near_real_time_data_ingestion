# =============================================================================
# Feature engineering jobs  (roadmap.md, Phase 7)
#
#   silver-binance-backfill : the downloaded archive -> the Silver klines table,
#                             under source=backfill
#   gold-market-features    : Silver klines + the CoinMarketCap as-of join ->
#                             the 1-minute feature table Phase 8 trains on
#
# Both are sized larger than the existing jobs and both are FLEX, which is the
# right pairing: FLEX runs on spare capacity for roughly a third of the price
# and in exchange gives no start-time guarantee. Neither of these is latency
# sensitive -- one is a one-time load, the other a daily batch with a 24-hour
# window -- so the guarantee is worth nothing here and the discount is real.
# =============================================================================

# -----------------------------------------------------------------------------
# Silver: the archive
#
# Shares the Silver execution role. That role already grants "read all of
# Bronze, write all of Silver", which is exactly this job's blast radius -- the
# same reasoning Phase 6 used when it gave silver_binance_job the same role
# rather than a second copy of the same permissions.
# -----------------------------------------------------------------------------
resource "aws_glue_job" "silver_binance_backfill" {
  name              = "silver-binance-backfill-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 10
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 240
  execution_class   = "FLEX"

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/silver_binance_backfill_job.py"
  }

  default_arguments = {
    "--JOB_NAME"                = "silver-binance-backfill-${var.environment}"
    "--BRONZE_BUCKET"           = var.bronze_bucket_id
    "--BRONZE_BACKFILL_PREFIX"  = var.bronze_backfill_prefix
    "--SILVER_BUCKET"           = var.silver_bucket_id
    "--SILVER_STREAMING_PREFIX" = var.silver_streaming_prefix

    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    # BOOKMARKS ARE OFF HERE, and that is the opposite of the streaming Silver
    # job on purpose. This job is not incremental: it re-derives whole months
    # from immutable files and writes them with dynamic partition overwrite, so
    # re-running a month range is how it is MEANT to be resumed. A bookmark
    # would make the second run of an interrupted load skip the objects it had
    # already read but not finished writing.
    "--job-bookmark-option" = "job-bookmark-disable"

    "--conf" = "spark.sql.parquet.compression.codec=snappy --conf spark.sql.shuffle.partitions=200 --conf spark.sql.sources.partitionOverwriteMode=dynamic --conf spark.sql.session.timeZone=UTC"

    "--enable-s3-parquet-optimized-committer" = "true"
    "--TempDir"                               = "s3://${var.artifacts_bucket_id}/tmp/"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Gold: the 1-minute feature table
# -----------------------------------------------------------------------------
resource "aws_glue_job" "gold_market_features" {
  name              = "gold-market-features-${var.environment}"
  role_arn          = aws_iam_role.glue_gold_base.arn
  glue_version      = "4.0"
  number_of_workers = 10
  worker_type       = "G.2X"
  max_retries       = 1
  timeout           = 240
  execution_class   = "FLEX"

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/gold_market_features_job.py"
  }

  default_arguments = {
    "--JOB_NAME"                    = "gold-market-features-${var.environment}"
    "--SILVER_BUCKET"               = var.silver_bucket_id
    "--SILVER_PREFIX"               = var.silver_prefix
    "--SILVER_STREAMING_PREFIX"     = var.silver_streaming_prefix
    "--GOLD_BUCKET"                 = var.gold_bucket_id
    "--GOLD_MARKET_FEATURES_PREFIX" = var.gold_market_features_prefix
    "--TRACKED_ASSETS_URI"          = "s3://${var.artifacts_bucket_id}/${aws_s3_object.tracked_assets_config.key}"
    "--INDICATORS_SQL_URI"          = "s3://${var.artifacts_bucket_id}/${aws_s3_object.indicators_sql.key}"
    "--FEATURE_BLOCK_VERSION"       = var.feature_block_version

    # The scheduled run covers the last two days, not nine years. Every window
    # in indicators.sql is time-bounded and the longest spans 1440 minutes, so
    # yesterday's features need yesterday plus a bounded tail -- which is what
    # keeps a daily job over a 133-million-row table affordable. The 2017 load
    # is the same job with --PROCESS_MODE full, run once, by hand.
    "--PROCESS_MODE"      = "incremental"
    "--PROCESS_DAYS_BACK" = "2"

    # The module that expands indicators.sql, shipped rather than duplicated.
    # It is the same file tests/test_indicators.py imports to run that SQL on
    # DuckDB, which is what makes the tested statement and the executed
    # statement the same statement.
    "--extra-py-files" = "s3://${var.artifacts_bucket_id}/${aws_s3_object.indicator_sql_module.key}"

    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    # No bookmarks. Incrementality here is PROCESS_FROM plus the warm-up window,
    # which is a different mechanism and a deliberate one: a bookmark tracks
    # which OBJECTS were read, and this job must deliberately re-read the tail
    # of the previous day every run so its rolling windows are full at midnight.
    # A bookmark would suppress exactly that re-read.
    "--job-bookmark-option" = "job-bookmark-disable"

    "--conf" = "spark.sql.parquet.compression.codec=snappy --conf spark.sql.shuffle.partitions=200 --conf spark.sql.sources.partitionOverwriteMode=dynamic --conf spark.sql.session.timeZone=UTC"

    "--enable-s3-parquet-optimized-committer" = "true"
    "--TempDir"                               = "s3://${var.artifacts_bucket_id}/tmp/"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Script and shared-artifact uploads
# -----------------------------------------------------------------------------
resource "aws_s3_object" "silver_binance_backfill_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/silver_binance_backfill_job.py"
  source                 = "${var.glue_scripts_dir}/silver/silver_binance_backfill_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/silver/silver_binance_backfill_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "gold_market_features_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/gold_market_features_job.py"
  source                 = "${var.glue_scripts_dir}/gold/gold_market_features_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/gold_market_features_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "indicator_sql_module" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/indicator_sql.py"
  source                 = "${var.glue_scripts_dir}/gold/indicator_sql.py"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/indicator_sql.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

# The indicator maths. Under config/ and not jobs/ because it is read as data by
# the job rather than executed as the job -- and because tests/test_indicators.py
# runs this exact text on DuckDB, which is the reason it is a file at all.
resource "aws_s3_object" "indicators_sql" {
  bucket                 = var.artifacts_bucket_id
  key                    = "config/indicators.sql"
  source                 = "${var.glue_scripts_dir}/gold/indicators.sql"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/indicators.sql")
  content_type           = "text/plain"
  server_side_encryption = "AES256"
}
