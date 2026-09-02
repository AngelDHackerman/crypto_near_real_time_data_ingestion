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
