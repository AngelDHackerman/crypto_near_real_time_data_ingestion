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
      aws_s3_bucket.silver.arn,
      aws_s3_bucket.gold.arn,
      aws_s3_bucket.artifacts.arn,
    ]
  }

  statement {
    sid       = "S3ReadSilver"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.silver.arn}/*"]
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
    resources = ["${aws_s3_bucket.gold.arn}/*"]
  }

  statement {
    sid       = "S3ReadJobScript"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/jobs/*"]
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
    resources = ["${aws_s3_bucket.artifacts.arn}/tmp/*"]
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
