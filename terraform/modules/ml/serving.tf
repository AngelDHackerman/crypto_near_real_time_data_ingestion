# =============================================================================
# Serving  (roadmap.md, Phase 10)
#
# model -> endpoint configuration -> endpoint, plus the Lambda that turns a
# symbol into a scored signal.
#
# ALL OF IT IS GATED, and unusually the gate is not primarily about cost. A
# SageMaker model resource requires a real model artifact: with no training run
# behind it, `serving_enabled = true` would fail the apply rather than create
# something expensive. So this gate protects the apply first and the bill
# second -- which is the opposite of streaming_enabled, and worth saying
# because the two look identical in the tfvars.
#
# ---------------------------------------------------------------------------
# SERVERLESS, AND THE VPC QUESTION THE ROADMAP PARKED HERE
# ---------------------------------------------------------------------------
#
# Phase 8 decided training needs no VPC and said the argument for one is
# genuinely stronger for SERVING. Having got here, the answer is still no, and
# for a reason that is a fact rather than a preference:
#
#   SAGEMAKER SERVERLESS INFERENCE DOES NOT SUPPORT VpcConfig AT ALL.
#
# So the choice is not "serverless with or without a VPC". It is:
#
#   serverless, no VPC     $0 at rest, pay per request, ~1-3s cold start
#   provisioned in a VPC   ~$50/month for the smallest always-on instance,
#                          plus a NAT Gateway or four interface endpoints
#
# The second is roughly triple the entire awake project's cost, permanently, to
# serve a demonstration endpoint. And it is worth being precise about what it
# would actually buy, because "private endpoint" sounds like it buys more than
# it does here: a SageMaker endpoint is NOT a public URL. It is an AWS API
# reached through InvokeEndpoint, authenticated with SigV4 and authorised by
# IAM. There is no anonymous access to remove. A VPC endpoint changes the
# NETWORK PATH -- it keeps traffic off the public internet and lets a security
# group and an endpoint policy constrain who can reach it -- which is a real
# control against a compromised-credential exfiltration path, and not the
# "otherwise anyone could call it" that the phrase usually implies.
#
# For a portfolio demonstration with one caller, in an account with a $40
# budget, that control is not worth triple the project's running cost. If this
# ever served real signals to real money the calculation changes, and the
# change is a provisioned endpoint config with a VpcConfig block -- which is
# why the decision is recorded here rather than left as an absence.
# =============================================================================

resource "aws_sagemaker_model" "signal" {
  count = var.serving_enabled ? 1 : 0

  name               = "${var.project}-signal-${var.environment}"
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    # From the REGISTRY, not from an S3 URI plus a hand-copied image name. That
    # is what the registry's InferenceSpecification is for, and it means the
    # thing deployed is a version with recorded metrics rather than a path
    # someone believed was the right one.
    model_package_name = var.model_package_arn
  }

  tags = var.tags
}

resource "aws_sagemaker_endpoint_configuration" "signal" {
  count = var.serving_enabled ? 1 : 0

  name = "${var.project}-signal-${var.environment}"

  production_variants {
    variant_name = "AllTraffic"
    model_name   = aws_sagemaker_model.signal[0].name

    serverless_config {
      # 2 GB is the smallest size that comfortably holds an XGBoost booster plus
      # the container's own footprint. Serverless bills per GB-second of actual
      # inference, so over-provisioning memory costs money on every request
      # rather than once.
      memory_size_in_mb = var.serving_memory_mb
      # One. This is a demonstration endpoint with one caller; a higher ceiling
      # would not make a single request faster and would raise the blast radius
      # of a runaway loop from "slow" to "a bill".
      max_concurrency = var.serving_max_concurrency
    }
  }

  # ---------------------------------------------------------------------------
  # Data capture -- the outcome of Phase 11's Model Monitor evaluation
  #
  # SageMaker Model Monitor was evaluated and DECLINED (roadmap.md, Phase 11):
  # it needs a scheduled Processing job, ~$7/month at the smallest useful size,
  # to watch an endpoint with one caller -- and what it detects is INPUT DRIFT,
  # while Phase 13 builds something strictly stronger for this project: whether
  # the predictions were actually RIGHT, measured against realised prices.
  #
  # Data capture is the half worth keeping, and it is nearly free: S3 puts and
  # storage, no compute. It writes every request and response to S3, which is
  # three things at once --
  #
  #   1. Phase 13's first DoD, "signals persisted with timestamp and
  #      prediction", satisfied by the platform instead of by a table this
  #      project would otherwise have to write and maintain;
  #   2. the ground truth job's input: what was predicted, and when;
  #   3. the option on Model Monitor kept open. Turning it on later needs
  #      history, and history cannot be collected retroactively -- which is the
  #      whole reason this is here now rather than in Phase 13.
  #
  # 100%, not a sample. At this volume a sample saves nothing and would make the
  # feedback loop's denominator an estimate.
  # ---------------------------------------------------------------------------
  data_capture_config {
    enable_capture              = true
    initial_sampling_percentage = 100
    destination_s3_uri          = "s3://${var.artifacts_bucket_id}/${var.ml_capture_prefix}"

    capture_options {
      capture_mode = "Input"
    }
    capture_options {
      capture_mode = "Output"
    }
  }

  tags = var.tags
}

resource "aws_sagemaker_endpoint" "signal" {
  count = var.serving_enabled ? 1 : 0

  name                 = "${var.project}-signal-${var.environment}"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.signal[0].name

  tags = var.tags
}

# -----------------------------------------------------------------------------
# The inference Lambda
#
# Gated with the endpoint, though for a different reason: a Lambda costs nothing
# at rest, but this one needs a DuckDB layer that is BUILT rather than committed
# (serving/inference/build_layer.sh, ~20 MB zipped). Creating the function
# without it would be the shape of Phase 5's unbuilt image all over again --
# infrastructure pointing at an artifact nobody made.
#
# So the precondition is stated once, here and in the roadmap: run the build
# script before flipping serving_enabled.
# -----------------------------------------------------------------------------
data "archive_file" "duckdb_layer" {
  count = var.serving_enabled ? 1 : 0

  type        = "zip"
  source_dir  = var.duckdb_layer_dir
  output_path = "${var.duckdb_layer_dir}/../duckdb_layer.zip"
  excludes    = ["../duckdb_layer.zip"]
}

resource "aws_lambda_layer_version" "duckdb" {
  count = var.serving_enabled ? 1 : 0

  layer_name          = "${var.project}-duckdb-${var.environment}"
  filename            = data.archive_file.duckdb_layer[0].output_path
  source_code_hash    = data.archive_file.duckdb_layer[0].output_base64sha256
  compatible_runtimes = ["python3.12"]
  description         = "DuckDB ${var.duckdb_version}, pinned to the version tests/test_indicators.py runs against. A serving engine on a different version than the tested one is training/serving skew with extra steps."
}

data "archive_file" "inference_lambda" {
  count = var.serving_enabled ? 1 : 0

  type        = "zip"
  output_path = var.inference_build_path

  source {
    content  = file("${var.inference_source_dir}/handler.py")
    filename = "handler.py"
  }
  source {
    content  = file("${var.inference_source_dir}/feature_request.py")
    filename = "feature_request.py"
  }
  # The SQL expander, shipped beside the handler rather than imported from a
  # path that only exists in the repository. Same module the Glue job gets via
  # --extra-py-files and the tests import directly.
  source {
    content  = file("${var.indicator_sql_module_path}")
    filename = "indicator_sql.py"
  }
}

data "aws_iam_policy_document" "inference_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "inference" {
  count = var.serving_enabled ? 1 : 0

  name               = "${var.project}-inference-lambda-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.inference_trust.json
  tags               = var.tags
}

# Counted, like the resources it describes. Without this the document evaluates
# even when serving is gated off, and its reference to the endpoint's ARN is
# then an index into an empty list -- a plan-time error rather than a no-op.
data "aws_iam_policy_document" "inference" {
  count = var.serving_enabled ? 1 : 0

  statement {
    sid       = "ReadRecentSilverKlines"
    actions   = ["s3:GetObject"]
    resources = ["${var.silver_bucket_arn}/${var.silver_klines_prefix}/*"]
  }

  statement {
    sid       = "ListRecentPartitions"
    actions   = ["s3:ListBucket"]
    resources = [var.silver_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.silver_klines_prefix}/*"]
    }
  }

  statement {
    sid     = "ReadFeatureContract"
    actions = ["s3:GetObject"]
    resources = [
      "${var.artifacts_bucket_arn}/config/*",
      "${var.artifacts_bucket_arn}/${var.ml_model_prefix}/*",
    ]
  }

  statement {
    sid       = "InvokeTheEndpoint"
    actions   = ["sagemaker:InvokeEndpoint"]
    resources = [aws_sagemaker_endpoint.signal[0].arn]
  }

  # Resource = "*" justified: the log group name contains the function name,
  # which contains a count index Terraform resolves at apply time. Same
  # justification carried by every other role in this project.
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "inference" {
  count = var.serving_enabled ? 1 : 0

  name   = "inference-lambda-access"
  role   = aws_iam_role.inference[0].id
  policy = data.aws_iam_policy_document.inference[0].json
}

resource "aws_lambda_function" "inference" {
  count = var.serving_enabled ? 1 : 0

  function_name    = "${var.project}-inference-${var.environment}"
  role             = aws_iam_role.inference[0].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.inference_lambda[0].output_path
  source_code_hash = data.archive_file.inference_lambda[0].output_base64sha256
  layers           = [aws_lambda_layer_version.duckdb[0].arn]

  # 1 GB and 60 s. The work is downloading ~50 small Parquet objects and running
  # a windowed query over ~1,500 rows -- neither is heavy, but a cold start that
  # also imports DuckDB needs room. Lambda scales CPU with memory, so raising
  # memory here shortens the run and is close to cost-neutral.
  memory_size = 1024
  timeout     = 60

  # /tmp holds the downloaded Parquet between invocations on a warm container,
  # which is why the handler checks before downloading. 512 MB is the default
  # and is ample for a 2-day window of one symbol.
  ephemeral_storage {
    size = 512
  }

  environment {
    variables = {
      SILVER_BUCKET        = var.silver_bucket_id
      SILVER_KLINES_PREFIX = var.silver_klines_prefix
      ARTIFACTS_BUCKET     = var.artifacts_bucket_id
      INDICATORS_SQL_KEY   = "config/indicators.sql"
      FEATURE_COLUMNS_KEY  = var.feature_columns_key
      ENDPOINT_NAME        = aws_sagemaker_endpoint.signal[0].name
      LOOKBACK_HOURS       = tostring(var.inference_lookback_hours)
    }
  }

  tags = var.tags
}
