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

resource "aws_glue_job" "gold_ml_features" {
  name              = "gold-ml-training-cmc-${var.environment}"
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
    "--JOB_NAME"             = "gold-ml-training-cmc-${var.environment}"
    "--GOLD_BUCKET"          = var.gold_bucket_id
    "--GOLD_FEATURES_PREFIX" = var.gold_features_prefix
    "--GOLD_ML_PREFIX"       = var.gold_ml_prefix
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
