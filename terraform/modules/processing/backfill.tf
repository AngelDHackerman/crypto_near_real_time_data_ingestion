# =============================================================================
# The historical backfill  (roadmap.md, Phase 7)
#
# A Python shell Glue job that downloads Binance's free 1-minute kline archive
# into Bronze. ~3,135 asset-months, ~133 million candles, ~4.4 GB, $0 in data
# charges -- it is an HTTPS fetch and an S3 put, and it never touches Kinesis or
# Firehose, so none of the streaming cost analysis applies to it.
#
# WHY PYTHON SHELL AND NOT A SPARK JOB. There is no join, no shuffle and no
# aggregation in this work: it is 3,135 downloads and 3,135 puts. A Spark
# cluster would bill executors to sit on sockets. 1 DPU with a thread pool is
# the right shape and the cheapest Glue there is.
#
# WHY THIS ONE IS NOT GATED. The project's rule is that everything BILLABLE gets
# a Terraform gate defaulting to off, and a gate means count = 0 when a resource
# bills merely by existing. A Glue job DEFINITION is free; only a run costs
# anything, and this job has no schedule and is not in the state machine. It is
# started deliberately, once, exactly like the wake-up flags -- so the gate here
# is that nothing invokes it, which is the honest form of the gate for a
# resource that costs nothing to exist.
# =============================================================================

# -----------------------------------------------------------------------------
# IAM -- its own role, because its blast radius is genuinely different
#
# Every other Glue role in this project READS Bronze. This one WRITES it, and it
# is the only thing in the account that does apart from Firehose and the
# extractor Lambda. Folding that into the Silver role would hand a job that
# processes Bronze the ability to overwrite it, which is the kind of grant that
# is invisible until the day something loops.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "glue_backfill" {
  name               = "${var.project}-glue-backfill-role"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "glue_backfill_policy" {
  statement {
    sid     = "S3ListBuckets"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      var.bronze_bucket_arn,
      var.artifacts_bucket_arn,
    ]
  }

  # Write scoped to the archive prefix, not to the bucket. Bronze also holds
  # `cmc/` and Firehose's `binance/`, and this job has no business in either --
  # the whole point of giving the archive its own top-level prefix was that the
  # streaming Silver job reads `binance/` recursively as JSON.
  statement {
    sid = "S3WriteBinanceArchive"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${var.bronze_bucket_arn}/${var.bronze_backfill_prefix}/*"]
  }

  # Deliberately no s3:DeleteObject anywhere in this role. The job is
  # idempotent by SKIPPING what already exists, never by clearing it, so the
  # permission would only be available for an accident.

  statement {
    sid       = "S3ReadJobScriptAndConfig"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/jobs/*", "${var.artifacts_bucket_arn}/config/*"]
  }

  statement {
    sid       = "S3WriteRunManifest"
    actions   = ["s3:PutObject"]
    resources = ["${var.artifacts_bucket_arn}/${var.backfill_manifest_prefix}/*"]
  }

  # Resource = "*" justified: Glue creates the log group and stream names at
  # runtime under /aws-glue/jobs/*, which are not known at plan time. Same
  # justification, and same scope, as the Gold role's logging statement.
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_backfill" {
  name   = "${var.project}-glue-backfill-policy"
  policy = data.aws_iam_policy_document.glue_backfill_policy.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_backfill" {
  role       = aws_iam_role.glue_backfill.name
  policy_arn = aws_iam_policy.glue_backfill.arn
}

# -----------------------------------------------------------------------------
# The job itself
# -----------------------------------------------------------------------------
resource "aws_glue_job" "backfill_binance_klines" {
  name     = "backfill-binance-klines-${var.environment}"
  role_arn = aws_iam_role.glue_backfill.arn

  # 1 DPU, not the 0.0625 minimum. The work is 3,135 sequential-ish HTTPS
  # round trips and the script runs them through a thread pool; the smaller
  # size caps memory at 1 GB and would turn a few hours into a day for a
  # difference of about a dollar.
  max_capacity = 1.0

  # Hours, not minutes. Glue's default timeout is 2880 minutes and leaving it
  # there would mean a stuck download holds a DPU for two days. Twelve hours is
  # comfortably more than the measured shape of this work and still bounded.
  timeout     = 720
  max_retries = 0 # re-running is a decision, not a reflex: the job is resumable by design

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${var.artifacts_bucket_id}/jobs/backfill_binance_klines.py"
  }

  default_arguments = {
    "--BRONZE_BUCKET"          = var.bronze_bucket_id
    "--BRONZE_BACKFILL_PREFIX" = var.bronze_backfill_prefix
    "--TRACKED_ASSETS_URI"     = "s3://${var.artifacts_bucket_id}/${aws_s3_object.tracked_assets_config.key}"
    "--MANIFEST_BUCKET"        = var.artifacts_bucket_id
    "--MANIFEST_PREFIX"        = var.backfill_manifest_prefix

    "--enable-continuous-cloudwatch-log" = "true"

    # MONTH_FROM / MONTH_TO / ONLY_SYMBOLS / FORCE are deliberately NOT defaults.
    # They are how a run is narrowed to a rehearsal, and a default here would be
    # a narrowing nobody asked for -- the full archive is the intended run.
  }

  tags = var.tags
}

resource "aws_s3_object" "backfill_script" {
  bucket                 = var.artifacts_bucket_id
  key                    = "jobs/backfill_binance_klines.py"
  source                 = "${var.glue_scripts_dir}/bronze/backfill_binance_klines.py"
  etag                   = filemd5("${var.glue_scripts_dir}/bronze/backfill_binance_klines.py")
  content_type           = "text/x-python"
  server_side_encryption = "AES256"
}

# -----------------------------------------------------------------------------
# config/ -- inputs that are neither scripts nor lake data
#
# tracked_assets.json is read at runtime by the backfill job and by the feature
# job, and indicators.sql by the feature job. Uploading them from the repo keeps
# the one-owner rule intact across the process boundary: the file Terraform
# reads to build the enum projections is the same file the jobs read to decide
# what to fetch and what to join.
#
# Under `config/` rather than `jobs/` because the IAM grants differ in kind --
# a script is executable, a config is data -- and because a future job that
# needs the universe should not have to be granted read on every job script to
# get it.
# -----------------------------------------------------------------------------
resource "aws_s3_object" "tracked_assets_config" {
  bucket                 = var.artifacts_bucket_id
  key                    = "config/tracked_assets.json"
  source                 = var.tracked_assets_file
  etag                   = filemd5(var.tracked_assets_file)
  content_type           = "application/json"
  server_side_encryption = "AES256"
}
