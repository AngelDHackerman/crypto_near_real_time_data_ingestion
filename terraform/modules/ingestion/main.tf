# =============================================================================
# Ingestion module -- the CMC extractor  (roadmap.md, Phase 3)
#
# Everything that puts raw data into the bronze bucket, plus the IAM that lets
# it: the Lambda, its role and policies, the secret it reads, and the
# EventBridge rule that fires it.
#
# The rule is currently DISABLED (var.rule_enabled = false) -- see "Current
# state: DORMANT" in roadmap.md. It is re-enabled in Phase 5, as code, never by
# clicking in the console.
#
# Phase 5 adds the Kinesis stream, Firehose and the Binance WebSocket producer
# alongside these resources; that is why this module is "ingestion" and not
# "lambda".
# =============================================================================

# -----------------------------------------------------------------------------
# Secret -- the CMC API key
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "near_real_time_crypto" {
  name        = "near_real_time_crypto_ingestion_secrets"
  description = "Secrets for Near Real-Time Crypto Ingestion"

  tags = {
    Project = "Crypto Near Real Time Data Ingestion"
    Env     = var.environment
  }
}

# -----------------------------------------------------------------------------
# Extractor Lambda
# -----------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = var.lambda_source_file
  output_path = var.lambda_build_path
}

# THE NAME CHANGED IN PHASE 6, and the old one is worth recording because it is
# a small lesson in how names rot. It was `fetch-top10-crypto-crypto`:
#
#   - "top10" was never true. The list was ELEVEN assets on the day this was
#     written, and it is FIFTY since Phase 4.
#   - "crypto-crypto" is the project word twice -- once from the original name,
#     once from the ${var.environment} suffix.
#
# `name` is ForceNew, so this is a destroy and a create rather than an update.
# That is why it waited: Phase 5's acceptance criterion was a plan with 0
# destroyed, and this could not fit inside it. Phase 6 already rebuilds this
# surface and the rule below is DISABLED, so nothing is interrupted -- the same
# reasoning Phase 3 used when it renamed the auto-generated target_ids.
#
# The log group is replaced with it, not merely renamed: its own name
# interpolates the function name, and a log group name is ForceNew too. That
# discards the old group's log streams. Acceptable here and nowhere near
# automatic in general -- this Lambda has been DISABLED since Phase 3, so the
# logs being dropped are from runs nobody is going to read.
resource "aws_lambda_function" "cmc_extractor" {
  function_name    = "cmc-extractor-${var.environment}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "app.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 120
  memory_size      = 512
  environment {
    variables = {
      RAW_BUCKET    = var.bronze_bucket_id
      BRONZE_PREFIX = var.bronze_prefix
      SECRET_ARN    = var.secrets_manager_arn
      TOP_LIST_ID   = join(",", var.tracked_asset_ids)
    }
  }
}

# The Terraform ADDRESS changed with the name, so the plan is told they are the
# same resource. It does not save the replacement -- function_name is ForceNew,
# so AWS destroys and creates either way -- but it makes the plan read as one
# replacement instead of an unrelated destroy next to an unrelated create.
moved {
  from = aws_lambda_function.fetch_top10_crypto
  to   = aws_lambda_function.cmc_extractor
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.cmc_extractor.function_name}"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# IAM -- lives next to the resource it serves (Phase 3 key principle)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "lambda-fetcher-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Write access to bronze, scoped to the one prefix the extractor owns.
data "aws_iam_policy_document" "lambda_s3_rw_bronze" {
  # Put/Get/Head
  statement {
    sid = "S3ObjectsRWInBronzePrefix"
    actions = [
      "s3:PutObject",
      "s3:GetObject"
    ]
    resources = [
      "${var.bronze_bucket_arn}/${var.bronze_prefix}/*"
    ]
  }
  # List the bucket, limited to the bronze prefix
  statement {
    sid       = "S3ListBucketBronzePrefixOnly"
    actions   = ["s3:ListBucket"]
    resources = [var.bronze_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.bronze_prefix}/*"]
    }
  }
}

resource "aws_iam_policy" "lambda_s3_rw_bronze" {
  name   = "lambda-s3-rw-${var.environment}-bronze"
  policy = data.aws_iam_policy_document.lambda_s3_rw_bronze.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3_rw_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_s3_rw_bronze.arn
}

# Access to Secrets Manager from Lambda.
# NOTE: this used to be a `data "aws_secretsmanager_secret"` lookup by hardcoded
# name, pointing at the very same secret this module creates as a resource. That
# is an implicit dependency Terraform cannot see: it breaks on a clean
# destroy/apply, and it duplicates the name in two places. Referencing the
# resource directly makes the dependency explicit.
resource "aws_iam_policy" "lambda_read_secret" {
  name        = "lambda-read-crypto-secret"
  description = "Allow lambda to read the crypto secret"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "ReadSecret",
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = aws_secretsmanager_secret.near_real_time_crypto.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_lambda_read_secret" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_read_secret.arn
}

# -----------------------------------------------------------------------------
# Schedule -- EventBridge -> Lambda
# -----------------------------------------------------------------------------
# Renamed in Phase 6, for the same reason as the Lambda above and one more.
# It was `schedule-fetch-top10-5-min-bronze-crypto`, which by Phase 5 was wrong
# three times over: not 10 assets (50), not every 5 minutes (hourly, since the
# 5-minute cadence was burning 86% of CoinMarketCap's free credit tier), and
# carrying "bronze" in a name where the destination is already obvious.
#
# THE CADENCE IS DELIBERATELY NOT IN THE NEW NAME. That is the whole failure
# mode being fixed: schedule_expression is a variable, and a name that repeats
# a variable's value is a second copy that cannot be kept in sync -- exactly the
# one-owner-per-fact rule Phase 2.1 applied to bucket names.
resource "aws_cloudwatch_event_rule" "extractor_schedule" {
  name                = "schedule-cmc-extractor-${var.environment}"
  description         = "Triggers the CoinMarketCap extractor Lambda, in env: ${var.environment}"
  schedule_expression = var.schedule_expression
  state               = var.rule_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "extractor_target" {
  rule = aws_cloudwatch_event_rule.extractor_schedule.name
  arn  = aws_lambda_function.cmc_extractor.arn

  # Was "terraform-20251011221948456600000001" -- the ID AWS auto-generated on
  # the original apply, pinned in Phase 1 because the import ID is
  # "<rule-name>/<target-id>" and an unnamed target is not addressable. Renamed
  # here now that the import is long behind us. target_id is ForceNew, so this
  # replaces the target: a delete plus a create of one pointer, not of the
  # Lambda it points at, and the rule is DISABLED anyway.
  target_id = "cmc-extractor-lambda"
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cmc_extractor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.extractor_schedule.arn
}
