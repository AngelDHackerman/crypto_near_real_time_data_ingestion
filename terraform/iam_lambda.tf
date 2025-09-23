# Create and attach basic lambda role for write logs
resource "aws_iam_role" "lambda_role" {
  name = "lambda-fetcher-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ 
        Effect="Allow", 
        Principal={ Service="lambda.amazonaws.com" }, 
        Action="sts:AssumeRole" 
    }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role              = aws_iam_role.lambda_role.name
  policy_arn        = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Give access to lambda to S3 Raw-Lake bucket
data "aws_iam_policy_document" "lambda_s3_rw_bronze" {
  # Put/Get/Head
  statement {
    sid = "S3ObjectsRWInBronzePrefix"
    actions = [
      "s3:PutObject",
      "s3:GetObject"
    ]
    resources = [
      "arn:aws:s3:::${var.bucket_lake_raw_name}/${var.bronze_prefix}/*"
    ]
  }
  # List the bucket, limited to the bronze prefix
  statement {
    sid = "S3ListBucketBronzePrefixOnly"
    actions = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.bucket_lake_raw_name}"]

    condition {
      test = "StringLike"
      variable = "s3:prefix"
      values = ["${var.bronze_prefix}/*"]
    }
  }
}

resource "aws_iam_policy" "lambda_s3_rw_bronze" {
  name   = "lambda-s3-rw-${var.environment}-lake-raw-top10_bronze"
  policy = data.aws_iam_policy_document.lambda_s3_rw_bronze.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3_rw_attach" {
  role        = aws_iam_role.lambda_role.name
  policy_arn  = aws_iam_policy.lambda_s3_rw_bronze.arn
}

# Access to Secrets Manager from Lambda
data "aws_secretsmanager_secret" "crypto" {
  name = "near_real_time_crypto_ingestion_secrets"
}

resource "aws_iam_policy" "lambda_read_secret" {
  name        = "lambda-read-crypto-secret"
  description = "Allow lambda to read the crypto secret"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "ReadSecret",
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = data.aws_secretsmanager_secret.crypto.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_lambda_read_secret" {
  role        = aws_iam_role.lambda_role.name
  policy_arn  = aws_iam_policy.lambda_read_secret.arn
}