###########################################
# IAM para Glue Job: Gold Features Base
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
  name                = "${var.project}-glue-gold-role"
  assume_role_policy  = data.aws_iam_policy_document.glue_gold_assume.json
  tags                = var.tags
}

# Minimum policy:
# ​​- Read script in artifacts
# - Read Silver (parquet) under ${var.silver_prefix}
# - Write Gold features under ${var.gold_features_prefix}
# - Logs to CloudWatch

data "aws_iam_policy_document" "glue_gold_policy" {
  # List buckets by prefix (artifacts and data)
  statement {
    sid     = "S3ListArtifactsAndDataByPrefix"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      "arn:aws:s3:::${var.bucket_artifacts_name}",
      "arn:aws:s3:::${var.bucket_silver_gold_name}",
    ]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${var.project}/glue/*",
        "${var.silver_prefix}/",
        "${var.silver_prefix}/*",
        "${var.gold_features_prefix}/",
        "${var.gold_features_prefix}/*",
      ]
    }
  }

  # Read .py script from artifacts
  statement {
    sid     = "S3GetArtifactsScript"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bucket_artifacts_name}/jobs/*"
    ]
  }

  # Read Silver Parquet
  statement {
    sid     = "S3ReadSilver"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.silver_prefix}/*"
    ]
  }

  # Write/update Gold Features partitions (dynamic job overwrite) :contentReference[oaicite:3]{index=3}
  statement {
    sid     = "S3WriteGoldFeatures"
    actions = [
      "s3:PutObject", 
      "s3:DeleteObject", 
      "s3:AbortMultipartUpload"
    ]
    resources = [
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_features_prefix}/*"
    ]
  }

  # Logs Glue → CloudWatch
  statement {
    sid     = "CloudWatchLogs"
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