# Trust policy for Glue service
data "aws_iam_policy_document" "glue_crawler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_crawler_role" {
  name               = "${var.project}-glue-crawler-role"
  assume_role_policy = data.aws_iam_policy_document.glue_crawler_assume.json
  tags               = var.tags
}

# Least-privilege policy for Glue crawler
data "aws_iam_policy_document" "glue_crawler_policy" {

  # Silver only. Gold lives in its own bucket now and uses partition projection,
  # so the crawler has no business there -- the prefix conditions that used to
  # keep these two apart inside one shared bucket are gone.
  statement {
    sid = "S3ListSilverBucket"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.silver.arn]
  }

  statement {
    sid       = "S3ReadSilverObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.silver.arn}/*"]
  }

  # Glue Catalog actions - restrict
  statement {
    sid = "GlueCatalogAccess"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateDatabase"
    ]
    resources = ["*"]
  }

  statement {
    sid = "GlueCatalogAccessTables"
    actions = [
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable"
    ]
    resources = ["*"]
  }

  # CloudWatch logs
  statement {
    sid       = "CWLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_crawler_policy" {
  name   = "${var.project}-glue-crawler-policy"
  policy = data.aws_iam_policy_document.glue_crawler_policy.json
}

# Attach AWS managed policy for Glue service role (covers many required actions)
resource "aws_iam_role_policy_attachment" "attach_service_role" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Attach your custom least-privilege policy on top
resource "aws_iam_role_policy_attachment" "attach_custom" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = aws_iam_policy.glue_crawler_policy.arn
}
