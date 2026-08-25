# =============================================================================
# envs/crypto -- composition only  (roadmap.md, Phase 3)
#
# This file wires modules together and nothing else. No resource is declared
# here; the only exceptions in this directory are tfstate.tf (the state bucket,
# which is infrastructure OF the infrastructure) and the data source in
# providers.tf.
#
# Note what does NOT appear below: bucket names, Glue job names, crawler names.
# Every one of those is an output of the module that creates the resource, so
# there is exactly one place in the codebase where each name is written. Holding
# the same name in two places is precisely what made the Phase 1 state recovery
# dangerous -- a typo in tfvars planned a destroy+recreate of the data lake.
#
# Relative paths below are resolved from THIS directory, because Terraform
# resolves relative paths against the root module. They are passed down as
# inputs so no module has to know where it sits in the repo.
# =============================================================================

locals {
  repo_root = "${path.module}/../../.."
}

# -----------------------------------------------------------------------------
# Storage -- the lake. Four buckets, one per purpose.
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  aws_account_id        = var.aws_account_id
  environment           = var.environment
  athena_results_prefix = var.athena_results_prefix
}

# -----------------------------------------------------------------------------
# Ingestion -- CMC extractor Lambda + its schedule.
# Phase 5 adds Kinesis, Firehose and the Binance producer here.
# -----------------------------------------------------------------------------
module "ingestion" {
  source = "../../modules/ingestion"

  environment         = var.environment
  bronze_bucket_id    = module.storage.bronze_bucket_id
  bronze_bucket_arn   = module.storage.bronze_bucket_arn
  bronze_prefix       = var.bronze_prefix
  secrets_manager_arn = var.secrets_manager_arn
  tracked_asset_ids   = var.tracked_asset_ids
  schedule_expression = var.eventbridge_schedule_expression
  rule_enabled        = var.eventbridge_rule_enabled

  lambda_source_file = "${local.repo_root}/extractor_bronze_lambda/app.py"
  lambda_build_path  = "${local.repo_root}/extractor_bronze_lambda/build/fetch_top10.zip"
}

# -----------------------------------------------------------------------------
# Catalog -- Glue databases, the Silver crawler, the Athena workgroup.
# -----------------------------------------------------------------------------
module "catalog" {
  source = "../../modules/catalog"

  project               = var.project
  environment           = var.environment
  tags                  = var.tags
  silver_bucket_id      = module.storage.silver_bucket_id
  silver_bucket_arn     = module.storage.silver_bucket_arn
  silver_prefix         = var.silver_prefix
  artifacts_bucket_id   = module.storage.artifacts_bucket_id
  athena_results_prefix = var.athena_results_prefix
}

# -----------------------------------------------------------------------------
# Processing -- the four Glue ETL jobs and their two roles.
# -----------------------------------------------------------------------------
module "processing" {
  source = "../../modules/processing"

  project     = var.project
  environment = var.environment
  tags        = var.tags

  bronze_bucket_id  = module.storage.bronze_bucket_id
  bronze_bucket_arn = module.storage.bronze_bucket_arn
  bronze_prefix     = var.bronze_prefix

  silver_bucket_id  = module.storage.silver_bucket_id
  silver_bucket_arn = module.storage.silver_bucket_arn
  silver_prefix     = var.silver_prefix

  gold_bucket_id       = module.storage.gold_bucket_id
  gold_bucket_arn      = module.storage.gold_bucket_arn
  gold_features_prefix = var.gold_features_prefix
  gold_ml_prefix       = var.gold_ml_prefix
  gold_ohlc_prefix     = var.gold_ohlc_prefix

  artifacts_bucket_id  = module.storage.artifacts_bucket_id
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn

  glue_scripts_dir = "${local.repo_root}/glue_jobs_silver_gold"
}

# -----------------------------------------------------------------------------
# Orchestration -- the daily state machine and its trigger.
# Job and crawler names come from the modules that create them, not from tfvars.
# -----------------------------------------------------------------------------
module "orchestration" {
  source = "../../modules/orchestration"

  environment = var.environment
  tags        = var.tags

  silver_job_name        = module.processing.silver_job_name
  gold_features_job_name = module.processing.gold_features_job_name
  gold_ohlc_job_name     = module.processing.gold_ohlc_job_name
  gold_ml_job_name       = module.processing.gold_ml_job_name
  silver_crawler_name    = module.catalog.silver_crawler_name

  daily_schedule_cron = var.sfn_daily_schedule_cron
}

# -----------------------------------------------------------------------------
# Observability -- failure detection and alerting.
# -----------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  environment       = var.environment
  sns_email         = var.sns_email
  state_machine_arn = module.orchestration.state_machine_arn
}
