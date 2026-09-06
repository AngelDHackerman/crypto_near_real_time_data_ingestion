# =============================================================================
# Processing module -- the four Glue ETL jobs  (roadmap.md, Phase 3)
#
# Silver reads Bronze; the three Gold jobs read Silver and each other's output.
# Two execution roles, because the blast radius genuinely differs: the Silver
# role never touches Gold, and the Gold role never touches Bronze.
#
# The aws_s3_object resources that upload the job scripts live here rather than
# in modules/storage/. A job script is a deployment artifact of the job that
# runs it, not a piece of the lake -- storage owns buckets, processing owns what
# it puts in them.
# =============================================================================

# -----------------------------------------------------------------------------
# IAM -- Silver job execution role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "glue_role" {
  name               = "AWSGlueServiceRole-cmc-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# Adjunta políticas administradas + inline mínima a S3 específicos
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Least privilege for the Silver job: read Bronze, write Silver, and touch only
# the two prefixes it actually needs inside artifacts.
#
# This used to grant PutObject/DeleteObject on artifacts/* with no prefix -- i.e.
# the ETL role could delete anything in the artifacts bucket, including the Glue
# scripts it runs. Scoped to jobs/ (read) and tmp/ (write) instead.
data "aws_iam_policy_document" "glue_s3" {
  statement {
    sid     = "S3ListBuckets"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      var.bronze_bucket_arn,
      var.silver_bucket_arn,
      var.artifacts_bucket_arn,
    ]
  }

  statement {
    sid       = "S3ReadBronze"
    actions   = ["s3:GetObject"]
    resources = ["${var.bronze_bucket_arn}/*"]
  }

  statement {
    sid = "S3WriteSilver"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]
    resources = ["${var.silver_bucket_arn}/*"]
  }

  statement {
    sid       = "S3ReadJobScript"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/jobs/*"]
  }

  statement {
    sid = "S3WriteSparkTempDir"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]
    resources = ["${var.artifacts_bucket_arn}/tmp/*"]
  }
}

resource "aws_iam_role_policy" "glue_s3_inline" {
  # Was "terraform-20250926203013591400000001", pinned in Phase 1 for the same
  # reason as the event targets: the import ID is "<role-name>:<policy-name>",
  # so an unnamed inline policy is not addressable.
  name   = "silver-job-s3-access"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_s3.json
}

# -----------------------------------------------------------------------------
# Glue job: Silver (Bronze -> Silver)
# -----------------------------------------------------------------------------
resource "aws_glue_job" "silver_job" {
  name              = "silver-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 60
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/silver_glue_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"           = "silver-cmc-${var.environment}"
    "--RAW_BUCKET"         = var.bronze_bucket_id
    "--RAW_PREFIX"         = var.bronze_prefix
    "--SILVER_BUCKET"      = var.silver_bucket_id
    "--SILVER_PREFIX"      = var.silver_prefix
    "--PARTITION_BY_ASSET" = "false"

    "--enable-glue-datacatalog"          = "true"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    "--conf" = "spark.sql.parquet.compression.codec=snappy --conf spark.sql.shuffle.partitions=8 --conf spark.sql.sources.partitionOverwriteMode=dynamic --conf spark.sql.session.timeZone=UTC"

    # Committer optimizado para S3 → menos archivos corruptos en fallos
    "--enable-s3-parquet-optimized-committer" = "true"

    "--TempDir" = "s3://${var.artifacts_bucket_id}/tmp/"
  }
}

# -----------------------------------------------------------------------------
# Glue job: Silver Binance stream (Bronze -> Silver)  (roadmap.md, Phase 6)
#
# A SECOND Silver job, not a change to the first. data_sources.md section 10
# settled that Silver stays source-separated and the join happens in Gold, and
# the two payloads have nothing in common: one is a CoinMarketCap quotes
# document, the other a Binance WebSocket frame. Merging them into one script
# would mean a CoinMarketCap schema change can break the stream.
#
# It shares the Silver execution role above deliberately. That role's grant is
# already "read all of bronze, write all of silver", which is exactly this
# job's blast radius too -- a second role would be a second copy of the same
# permissions, not a smaller one.
#
# NOT GATED ON streaming_enabled. A Glue job definition is free; only a job RUN
# costs anything, and nothing runs while the state machine's schedule is
# disabled. Same reasoning as the ECR repository and task definition in Phase 5:
# gate what bills, not what merely exists.
# -----------------------------------------------------------------------------
resource "aws_glue_job" "silver_binance_job" {
  name              = "silver-binance-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 60
  execution_class   = "FLEX"

  command {
    name            = "glueetl"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/silver_binance_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"                = "silver-binance-${var.environment}"
    "--BRONZE_BUCKET"           = var.bronze_bucket_id
    "--BRONZE_STREAMING_PREFIX" = var.bronze_streaming_prefix
    "--SILVER_BUCKET"           = var.silver_bucket_id
    "--SILVER_STREAMING_PREFIX" = var.silver_streaming_prefix

    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    # BOOKMARKS ARE LATCHED ON HERE, not a default inherited by accident. They
    # are what makes this job incremental, and they track OBJECTS rather than
    # partitions -- which matters more for this job than for any other in the
    # project, because Firehose's `year=/month=/day=/hour=` prefix is ARRIVAL
    # time, not event time. A partition-based watermark would silently skip
    # events that landed in an object whose path disagrees with its contents.
    "--job-bookmark-option" = "job-bookmark-enable"

    "--conf" = "spark.sql.parquet.compression.codec=snappy --conf spark.sql.shuffle.partitions=8 --conf spark.sql.sources.partitionOverwriteMode=dynamic --conf spark.sql.session.timeZone=UTC"

    "--enable-s3-parquet-optimized-committer" = "true"

    "--TempDir" = "s3://${var.artifacts_bucket_id}/tmp/"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# IAM -- shared Gold jobs execution role
# -----------------------------------------------------------------------------
###########################################
# IAM para Glue Job: Gold (Features Base + ML Training)
###########################################

# Trust policy (Glue Service)
data "aws_iam_policy_document" "glue_gold_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_gold_base" {
  name               = "${var.project}-glue-gold-role"
  assume_role_policy = data.aws_iam_policy_document.glue_gold_assume.json
  tags               = var.tags
}

# Política del job:
# - ListBucket sin condición para artifacts y data
# - Leer script del job en artifacts/jobs/*
# - (NEW) Escribir y leer en artifacts/tmp/* (por --TempDir)
# - Leer Parquet en GOLD_FEATURES_BASE (input del job ML)
# - Escribir en GOLD (prefijo padre y subcarpetas: features_base y ml_training)
# - Logs en CloudWatch
# Least privilege for the Gold jobs: read Silver, read+write Gold, script from
# artifacts/jobs, scratch in artifacts/tmp.
#
# Every bucket here is single-purpose now, so the resources are plain bucket ARNs.
# That deletes the nine-ARN "$folder$" block the old policy needed to cover
# top10/gold, top10/gold_$folder$, top10/gold/* and the same triple for each
# sub-prefix -- an artifact of Silver and Gold sharing one bucket.
data "aws_iam_policy_document" "glue_gold_policy" {

  statement {
    sid     = "S3ListBuckets"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      var.silver_bucket_arn,
      var.gold_bucket_arn,
      var.artifacts_bucket_arn,
    ]
  }

  statement {
    sid       = "S3ReadSilver"
    actions   = ["s3:GetObject"]
    resources = ["${var.silver_bucket_arn}/*"]
  }

  # Covers both directions: gold_features_base is written by one job and read as
  # input by the OHLC and ML jobs.
  statement {
    sid = "S3ReadWriteGold"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]
    resources = ["${var.gold_bucket_arn}/*"]
  }

  statement {
    sid       = "S3ReadJobScript"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/jobs/*"]
  }

  # Phase 7: the feature job reads two things that are inputs rather than code
  # -- config/tracked_assets.json for the symbol-to-cmc_id bridge, and
  # config/indicators.sql for the maths. Granted as its own statement instead of
  # widening the one above, so "may execute a job script" and "may read a config"
  # stay separate permissions.
  statement {
    sid       = "S3ReadJobConfig"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/config/*"]
  }

  statement {
    sid = "S3WriteSparkTempDir"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]
    resources = ["${var.artifacts_bucket_arn}/tmp/*"]
  }

  # Resource = "*" justified: Glue creates its own log group and stream names at
  # runtime under /aws-glue/jobs/*, which are not known at plan time.
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_gold_policy" {
  name   = "${var.project}-glue-gold-policy"
  policy = data.aws_iam_policy_document.glue_gold_policy.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_gold_attach" {
  role       = aws_iam_role.glue_gold_base.name
  policy_arn = aws_iam_policy.glue_gold_policy.arn
}

# -----------------------------------------------------------------------------
# Glue job: Gold features base
# -----------------------------------------------------------------------------
#############################
# Glue Job: Gold Features Base
#############################

resource "aws_glue_job" "gold_features_base" {
  name              = "gold-base-features-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_gold_base.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 30
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/gold_features_base_job.py"
  }

  # Pass the parameters required by gold_features_base.py 
  # (match getResolvedOptions of the script: SILVER_BUCKET, SILVER_PREFIX, GOLD_BUCKET, GOLD_FEATURES_PREFIX, PROCESS_FROM) :contentReference[oaicite:2]{index=2}
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${var.artifacts_bucket_id}/tmp/"

    # 🔖 Bookmarks
    "--job-bookmark-option" = "job-bookmark-enable"

    # Business Arguments
    "--JOB_NAME"             = "gold-base-features-cmc-${var.environment}"
    "--SILVER_BUCKET"        = var.silver_bucket_id
    "--SILVER_PREFIX"        = var.silver_prefix
    "--GOLD_BUCKET"          = var.gold_bucket_id
    "--GOLD_FEATURES_PREFIX" = var.gold_features_prefix

  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Glue job: Gold OHLC
# -----------------------------------------------------------------------------
#############################
# Glue Job: Gold Open, High, Low, Close 
# views of: hour, day, week and month
#############################

resource "aws_glue_job" "gold_ohlc" {
  name              = "gold-ohlc-day-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_gold_base.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 30
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/gold_ohlc_h_d_w_m.py"
  }

  # Pass the parameters required by gold_ohlc_h_d_w_m.py
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${var.artifacts_bucket_id}/tmp/"

    # 🔖 Bookmarks
    "--job-bookmark-option" = "job-bookmark-enable"

    # Business Arguments
    "--JOB_NAME"             = "gold-ohlc-day-cmc-${var.environment}"
    "--GOLD_FEATURES_PREFIX" = var.gold_features_prefix
    "--GOLD_BUCKET"          = var.gold_bucket_id
    "--GOLD_OHLC_PREFIX"     = var.gold_ohlc_prefix
    "--GRAIN"                = "day" # "hour" | "day" | "week" | "month" Option to create another glue job with different time window
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Glue job: Gold ML training
# -----------------------------------------------------------------------------
#############################
# Glue Job: Gold Machine Learning Training
#############################

# PHASE 7 REPOINTED THIS JOB. It used to read gold_features_base -- daily
# CoinMarketCap snapshots -- and label "did the price rise 2% tomorrow". It now
# reads the 1-minute feature table and labels a cost-aware forward return. The
# reasoning is in the script's header; the consequence here is a different input
# prefix, two label parameters, and a size that reflects reading nine years of
# minutes instead of a few weeks of days.
#
# THE NAME STILL SAYS "cmc" AND IT NO LONGER SHOULD. Gold is source-agnostic by
# definition -- Phase 2.1 made its prefixes dataset names for exactly that
# reason -- and this job has not read a CoinMarketCap table since this commit.
# Renaming a Glue job is ForceNew, and Phase 6 established that the right moment
# for a ForceNew rename is when the resource is idle and nothing is behind it,
# which is true here. It is deliberately NOT bundled into this phase anyway:
# Phase 6's rename was approved as its own decision with its own destroy count,
# and quietly attaching three more destroys to an unrelated phase is how a plan
# stops being reviewable. Carried in the backlog instead.
resource "aws_glue_job" "gold_ml_features" {
  name              = "gold-ml-training-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_gold_base.arn
  glue_version      = "4.0"
  number_of_workers = 10
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 240
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/gold_ml_training_job.py"
  }

  # Pass the parameters required by gold_ml_training_job.py 
  # (match getResolvedOptions of the script: SILVER_BUCKET, SILVER_PREFIX, GOLD_BUCKET, GOLD_FEATURES_PREFIX, PROCESS_FROM) :contentReference[oaicite:2]{index=2}
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${var.artifacts_bucket_id}/tmp/"

    # 🔖 Bookmarks
    "--job-bookmark-option" = "job-bookmark-enable"

    # Business Arguments
    "--JOB_NAME"                    = "gold-ml-training-cmc-${var.environment}"
    "--GOLD_BUCKET"                 = var.gold_bucket_id
    "--GOLD_MARKET_FEATURES_PREFIX" = var.gold_market_features_prefix
    "--GOLD_ML_PREFIX"              = var.gold_ml_prefix
    "--FEATURE_BLOCK_VERSION"       = var.feature_block_version

    # The target's definition, as job arguments rather than as constants in the
    # script. Phase 13 compares a challenger against a champion and that
    # comparison is only meaningful across one target, so the definition has to
    # be something a plan shows changing -- not something a commit buries.
    "--LABEL_HORIZON_MIN"   = tostring(var.label_horizon_min)
    "--LABEL_THRESHOLD_BPS" = tostring(var.label_threshold_bps)

    # Three days, one more than the feature job's two. A row cannot be labelled
    # until its forward window has elapsed, so the tail the previous run had to
    # leave unlabelled is exactly what this run has to come back for.
    "--PROCESS_MODE"      = "incremental"
    "--PROCESS_DAYS_BACK" = "3"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Glue job scripts -- uploaded from the repo into the artifacts bucket
# -----------------------------------------------------------------------------
resource "aws_s3_object" "silver_glue_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/silver_glue_job.py"
  source                 = "${var.glue_scripts_dir}/silver/silver_glue_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/silver/silver_glue_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "silver_binance_glue_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/silver_binance_job.py"
  source                 = "${var.glue_scripts_dir}/silver/silver_binance_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/silver/silver_binance_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "gold_features_base_glue_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/gold_features_base_job.py"
  source                 = "${var.glue_scripts_dir}/gold/gold_features_base_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/gold_features_base_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "gold_ml_training_glue_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/gold_ml_training_job.py"
  source                 = "${var.glue_scripts_dir}/gold/gold_ml_training_job.py"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/gold_ml_training_job.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "gold_ohlc_glue_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/gold_ohlc_h_d_w_m.py"
  source                 = "${var.glue_scripts_dir}/gold/gold_ohlc_h_d_w_m.py"
  etag                   = filemd5("${var.glue_scripts_dir}/gold/gold_ohlc_h_d_w_m.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}
