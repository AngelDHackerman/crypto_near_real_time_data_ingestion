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
      aws_s3_bucket.bronze.arn,
      aws_s3_bucket.silver.arn,
      aws_s3_bucket.artifacts.arn,
    ]
  }

  statement {
    sid       = "S3ReadBronze"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bronze.arn}/*"]
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
    resources = ["${aws_s3_bucket.silver.arn}/*"]
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
}

resource "aws_iam_role_policy" "glue_s3_inline" {
  # Pinned to the AWS-generated name from the original apply: the import ID is
  # "<role-name>:<policy-name>", and leaving it unnamed would make every plan
  # propose a replacement. Renamed in Phase 3, as a deliberate change.
  name   = "terraform-20250926203013591400000001"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_s3.json
}
