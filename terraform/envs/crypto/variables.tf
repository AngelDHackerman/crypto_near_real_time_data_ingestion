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

# --- Tracked assets ---------------------------------------------------------
variable "tracked_asset_ids" {
  description = "CoinMarketCap ids to fetch. Renamed from top10_list_id in Phase 3: the name already lied at 11 ids, and Phase 4 replaces the list with a curated, FIXED set of 50 -- hand-picked, never a live ranking."
  type        = list(number)
}

# --- Schedules --------------------------------------------------------------
variable "eventbridge_schedule_expression" {
  description = "Cron/rate expression driving the CMC extractor Lambda."
  type        = string
  default     = "rate(5 minutes)"
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

# --- Notifications ----------------------------------------------------------
variable "sns_email" {
  description = "Address subscribed to the pipeline failure alerts topic."
  type        = string
}
