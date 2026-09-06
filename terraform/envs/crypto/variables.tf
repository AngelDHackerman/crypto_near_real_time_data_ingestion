# =============================================================================
# envs/crypto -- input variables
#
# What is NOT here any more, and why (roadmap.md, Phase 3):
#
#   bucket_lake_raw_name / bucket_silver_gold_name / bucket_artifacts_name
#       Deleted in Phase 2.1. The aws_s3_bucket resources own their own names.
#
#   glue_job_silver / glue_job_gold_features / glue_job_gold_ohlc /
#   glue_job_gold_ml / silver_crawler_name
#       Same rule, applied beyond buckets. These were the SECOND copy of a name
#       the resource already defines; the state machine now reads them from
#       module.processing / module.catalog outputs, so a job rename can no
#       longer silently desynchronise the orchestration that calls it.
#
#   top10_list_symbol
#       Declared, set in tfvars, referenced by nothing. Dead since it was
#       written.
#
#   gold_job_name / glue_version / glue_worker_type / glue_number_of_workers /
#   secrets_manager_name
#       Same story: declared, never referenced. The Glue jobs hardcode their
#       sizing inline, which is where it actually is.
#
#   gold_spark_ui_prefix
#       Deleted in Phase 2.1. Its orphaned comment ("Prefijos para Spark UI y
#       TempDir dentro del bucket GOLD"), left stranded above an unrelated
#       variable, is deleted here.
#
#   tracked_asset_ids
#       Deleted in Phase 5. The frozen 50 live in config/tracked_assets.json,
#       which main.tf reads directly -- the same one-owner-per-fact rule, now
#       applied to the asset list. Keeping it here as well would put the list in
#       two places, and tfvars is gitignored, so the second copy would be
#       invisible to review and different on every machine.
#
#       IF YOUR LOCAL tfvars STILL SETS IT, delete that line. Terraform only
#       warns about a value for an undeclared variable, so it will not fail --
#       it will just quietly do nothing, which is worse.
# =============================================================================

variable "aws_account_id" {
  description = "AWS account ID that owns every resource in this project. Pins the provider (allowed_account_ids) and suffixes the S3 bucket names."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "environment" {
  description = "Environment name. Suffixes most resource names; also the directory name under envs/."
  type        = string
}

variable "project" {
  description = "Project tag/name. Prefixes the Athena workgroup, the crawler and the Gold Glue role."
  type        = string
  default     = "near-real-time-crypto"
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default = {
    Owner   = "Angel"
    Purpose = "Near Real Time Data Ingestion Crypto Project"
  }
}

# --- Secrets ----------------------------------------------------------------
variable "secrets_manager_arn" {
  description = "ARN of the Secrets Manager secret holding the CMC API key, as passed to the Lambda environment."
  type        = string
}

# --- Prefixes ---------------------------------------------------------------
# Top level inside a lake bucket is the SOURCE, never the layer -- the bucket
# already names the layer. Gold is source-agnostic by definition: it IS the
# join, so its prefixes are dataset names.
variable "bronze_prefix" {
  description = "Top-level prefix inside the bronze bucket. \"cmc\" today; \"binance\" joins it in Phase 5."
  type        = string
}

variable "silver_prefix" {
  description = "Top-level prefix inside the silver bucket. Source-based, same rule as bronze_prefix."
  type        = string
}

variable "gold_features_prefix" {
  description = "Dataset prefix for the Gold features base."
  type        = string
}

variable "gold_ml_prefix" {
  description = "Dataset prefix for the ML training set."
  type        = string
}

variable "gold_ohlc_prefix" {
  description = "Dataset prefix for the OHLC aggregates."
  type        = string
}

variable "athena_results_prefix" {
  description = "Prefix inside the artifacts bucket where Athena writes query results."
  type        = string
}

# --- Schedules --------------------------------------------------------------
variable "eventbridge_schedule_expression" {
  description = <<-EOT
    Cron/rate expression driving the CMC extractor Lambda.

    Hourly since Phase 5, down from every 5 minutes. That cadence was never a
    design choice: 5 minutes is 8,640 calls/month against CoinMarketCap's
    10,000-credit free tier -- 86% of quota, i.e. the ceiling. Hourly with the
    frozen 50 costs 730 credits/month, 7.3%, because quotes/latest bills 1
    credit per call per 100 ids, so 50 ids in one batched call is still 1
    credit. Tick-granularity data now comes from the Binance stream; what CMC
    uniquely provides -- market cap, supply, dominance -- does not move fast
    enough to justify polling it twelve times an hour.

    NOTE: this default is overridden by terraform.tfvars, which is gitignored.
    Changing it here does not change a deployment that sets it there.
  EOT
  type        = string
  default     = "rate(1 hour)"
}

variable "eventbridge_rule_enabled" {
  description = "Enable/disable the extractor's EventBridge rule. False while the project is dormant; Phase 5 flips it to true, as code."
  type        = bool
  default     = true
}

variable "sfn_daily_schedule_cron" {
  description = "EventBridge cron (UTC) driving the daily Silver -> Gold state machine."
  type        = string
  default     = "cron(0 0 * * ? *)"
}

# --- Streaming (Phase 5) ----------------------------------------------------
variable "streaming_enabled" {
  description = <<-EOT
    THE COST GATE for the Binance streaming path. False, and it stays false.

    Not the same kind of switch as eventbridge_rule_enabled. A DISABLED
    EventBridge rule is free, so it can exist while switched off; a Kinesis
    shard bills ~$10.95/month from the moment it is created, at zero traffic.
    So this drives `count` -- the stream and its Firehose must NOT EXIST -- and
    drives the producer service to desired_count = 0.

    With it false, `terraform apply` still builds the whole streaming stack:
    VPC, security group, ECR repository, task definition, both IAM roles, log
    groups, the ECS cluster and service. All of it free. Opening the gate is one
    variable, not a rebuild.

    Flipping this to true starts a ~$25/month bill (~$12.62 ingestion +
    ~$12.66 producer). Do it deliberately, at the end of the project, as code.
  EOT
  type        = bool
  default     = false
}

variable "bronze_streaming_prefix" {
  description = "Top-level prefix in bronze for the Binance stream, alongside \"cmc\". The SOURCE, not the layer."
  type        = string
  default     = "binance"
}

# --- Phase 6 -----------------------------------------------------------------
variable "silver_streaming_prefix" {
  description = "Top-level prefix in silver for the Binance stream, alongside \"cmc\". Mirrors bronze_streaming_prefix one layer up. The Silver job writes trades/ and klines/ underneath it."
  type        = string
  default     = "binance"
}

variable "streaming_projection_start_date" {
  description = <<-EOT
    Lower bound of the `dt` partition projection on the two Binance Silver
    tables (yyyy-MM-dd). The upper bound is NOW, so only this end is a setting.

    It is a correctness knob, not cosmetics: a row written OUTSIDE the projected
    range is invisible to Athena rather than an error. 2026-09-01 is the month
    the streaming stack was built and there is no data behind it yet, so this is
    a floor, not a claim about when data starts. Phase 7's 2017 backfill must
    widen it in the same change that writes those rows.
  EOT
  type        = string
  default     = "2026-09-01"
}

variable "sfn_daily_schedule_enabled" {
  description = <<-EOT
    Whether the daily Silver -> Gold EventBridge rule is ENABLED. False while
    the project is dormant, which is its default state.

    Added in Phase 6, closing a gap rather than adding a feature: this rule
    starts an execution that runs five Glue jobs, and its `state` was not set
    in Terraform at all -- so the fact that it was switched off lived in the
    AWS console and nowhere in this repository.

    It is a `state` flag and not a `count` gate, on purpose. A DISABLED
    EventBridge rule is free, so it may exist while off; that is the same
    distinction Phase 5 drew when `streaming_enabled` had to drive `count`,
    because a Kinesis shard bills from creation.
  EOT
  type        = bool
  default     = false
}

# --- Cost guard (Phase 5) ---------------------------------------------------
variable "monthly_budget_usd" {
  description = "AWS Budgets threshold for the whole account. Set BEFORE the streaming gate is ever opened, so it is already watching rather than being added after a surprise. Deliberately just above the ~$25/month the project costs awake: it should fire on a mistake, not on normal operation."
  type        = number
  default     = 40
}

# --- Notifications ----------------------------------------------------------
variable "sns_email" {
  description = "Address subscribed to the pipeline failure alerts topic."
  type        = string
}

# --- Phase 7 -----------------------------------------------------------------
# Every variable below carries a default, on purpose. terraform.tfvars is
# gitignored and exists on one machine (a still-open backlog item), so a new
# REQUIRED variable is a change that breaks any apply from anywhere else with an
# error that reads like a bug. Defaults here mean Phase 7 applies from a clean
# checkout; anything genuinely environment-specific still belongs in tfvars.

variable "bronze_backfill_prefix" {
  description = <<-EOT
    Top-level prefix in bronze for the downloaded Binance kline archive.

    A SIBLING of `binance/`, not a child, and the distinction is load-bearing:
    the streaming Silver job reads `binance/` recursively as newline-delimited
    JSON, so a CSV underneath it would be parsed as JSON and produce a frame of
    nulls rather than an error.
  EOT
  type        = string
  default     = "binance_archive"
}

variable "backfill_manifest_prefix" {
  description = "Prefix in the artifacts bucket for backfill run manifests -- every file written, its published SHA-256, its row count and its detected timestamp unit. Artifacts and not bronze: a manifest is not lake data, and it would break partition discovery under the archive prefix."
  type        = string
  default     = "backfill/manifests"
}

variable "gold_market_features_prefix" {
  description = "Dataset prefix for the 1-minute feature table. Gold prefixes are dataset names, never source names -- Gold is the join."
  type        = string
  default     = "gold_market_features_1m"
}

variable "backfill_projection_start_date" {
  description = <<-EOT
    Lower bound of the `dt` projection on every table carrying backfilled
    history: the Binance Silver klines table and the two 1-minute Gold tables.

    2017-07 is Binance's own opening month, so this is the earliest a row can
    exist rather than a date someone picked. It is separate from
    streaming_projection_start_date because that one bounds tables the stream
    alone writes, and widening those to 2017 would make Athena enumerate nine
    years of partitions that cannot exist.
  EOT
  type        = string
  default     = "2017-07-01"
}

variable "feature_block_version" {
  description = "Stamped on every row of the feature table. Phase 8 records a baseline metric, and a baseline measured against a feature definition that later changed is not a baseline -- so changing indicators.sql means changing this in the same commit."
  type        = string
  default     = "v1"
}

variable "label_horizon_min" {
  description = "Forward horizon of the training label, in minutes. Also the sampling stride, so that consecutive retained rows have disjoint label windows."
  type        = number
  default     = 60
}

variable "label_threshold_bps" {
  description = <<-EOT
    Basis points the forward return must exceed for a positive label.

    20 bps is a round-trip Binance taker fee (10 bps a side) before slippage.
    Labelling "went up" instead would mark a great many moves that would have
    lost money, and a model that predicts those perfectly is worthless. This
    is what makes the target mean something; it does not make the output
    actionable -- the project's stated goal still holds.
  EOT
  type        = number
  default     = 20
}

# --- Phase 8 -----------------------------------------------------------------
variable "ml_code_prefix" {
  description = "Prefix in the artifacts bucket for packaged training source directories, one per training job. Keyed by job name rather than overwritten, because a model's provenance has to stay fetchable for as long as the model does -- Phase 9 registers versions that point at it."
  type        = string
  default     = "ml/code"
}

variable "ml_model_prefix" {
  description = "Prefix in the artifacts bucket where SageMaker writes model artifacts. In artifacts and not gold: a model is not lake data, which is the standing rule from Phase 2.1."
  type        = string
  default     = "ml/models"
}

# --- Phase 10 ----------------------------------------------------------------
variable "serving_enabled" {
  description = <<-EOT
    Gate for the inference path: the SageMaker model, its endpoint config, the
    serverless endpoint, and the Lambda that turns a symbol into a score.

    A different KIND of gate from streaming_enabled, and the difference matters
    when reading tfvars. streaming_enabled guards a recurring bill -- a Kinesis
    shard costs $10.95/month from creation. This one guards the APPLY: an
    aws_sagemaker_model requires a real model artifact, so setting it true
    before a training run has produced one fails the plan rather than creating
    something expensive. Serverless inference itself is $0 at rest.

    TWO PRECONDITIONS before this can be true:
      1. a promoted model package ARN in model_package_arn, from
         ml/registry/promote_model.py
      2. the DuckDB Lambda layer built -- serving/inference/build_layer.sh
    Both are stated here rather than discovered later, which is the lesson from
    Phase 5's unbuilt producer image.
  EOT
  type        = bool
  default     = false
}

variable "model_package_arn" {
  description = "The registry version to serve. Empty while serving is gated off. Comes from the registry rather than from a hand-copied S3 URI, so the deployed model's metrics stay recoverable."
  type        = string
  default     = ""
}
