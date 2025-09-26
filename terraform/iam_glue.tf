resource "aws_iam_role" "glue_role" {
  name = "AWSGlueServiceRole-cmc-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# Adjunta políticas administradas + inline mínima a S3 específicos
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Allow least previliges in S3
data "aws_iam_policy_document" "glue_s3" {
  statement {
    actions = ["s3:ListBucket"]
    resources = [
        "arn:aws:s3:::${var.bucket_lake_raw_name}",
        "arn:aws:s3:::${var.bucket_silver_gold_name}",
        "arn:aws:s3:::${var.bucket_artifacts_name}",
    ]
  }
  statement {
    actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
    ]
    resources = [
      "arn:aws:s3:::${var.bucket_lake_raw_name}/*",
      "arn:aws:s3:::${var.bucket_silver_gold_name}/*",
      "arn:aws:s3:::${var.bucket_artifacts_name}/*"
    ]
  }
}

resource "aws_iam_role_policy" "glue_s3_inline" {
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_s3.json
}
