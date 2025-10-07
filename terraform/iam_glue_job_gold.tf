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
data "aws_iam_policy_document" "glue_gold_policy" {

  # ---- S3: List buckets (sin condición) ----
  statement {
    sid     = "S3ListDataBucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.bucket_silver_gold_name}"]
  }

  statement {
    sid     = "S3ListArtifactsBucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.bucket_artifacts_name}"]
  }

  # ---- Artifacts: escribir/borrar en TempDir ----
  statement {
    sid     = "S3WriteArtifactsTempDir"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:GetObject"
    ]
    resources = [
      "arn:aws:s3:::${var.bucket_artifacts_name}/tmp/*"
    ]
  }

  # ---- Silver: lectura de Parquet (si algún job lo usa) ----
  statement {
    sid     = "S3ReadSilver"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.silver_prefix}/*"
    ]
  }

  # ---- (NEW) Gold Features Base: lectura (input del job ML) ----
  statement {
    sid     = "S3ReadGoldFeaturesBase"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_features_prefix}/*"
    ]
  }

  # ---- Gold: escritura (prefijo padre + subcarpetas) ----
  # Cubre marcadores $folder$, _SUCCESS, _temporary, etc.
  statement {
    sid     = "S3WriteGoldArea"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload"
    ]
    resources = [
      # Prefijo padre (top10/gold)
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_prefix}",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_prefix}_$folder$",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_prefix}/*",

      # subprefijo específico de features_base
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_features_prefix}",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_features_prefix}_$folder$",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_features_prefix}/*",

      # subprefijo específico de ml_training
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_ml_prefix}",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_ml_prefix}_$folder$",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/${var.gold_ml_prefix}/*"
    ]
  }

  # ---- Logs Glue → CloudWatch ----
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
