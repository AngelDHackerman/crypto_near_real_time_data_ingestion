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

  # -----------------------------------------------------------------------
  # The tracked universe is read from config/tracked_assets.json, not held in
  # tfvars (roadmap.md, Phase 5; data_sources.md section 12).
  #
  # This applies to the asset list the same rule Phase 2.1 applied to bucket
  # names and Phase 3 to job names: ONE OWNER PER FACT. The Lambda, the
  # producer and -- from Phase 7 -- the backfill and the Gold join all read
  # this same file, so they cannot drift apart in what they track. A list in
  # tfvars would be a second copy, and tfvars is gitignored, so that copy would
  # be invisible to review and different on every machine.
  #
  # The file is the FROZEN, hand-picked 50. Deliberately not a live top-50
  # ranking: a dynamic universe silently changes what is tracked and makes the
  # training set non-reproducible.
  # -----------------------------------------------------------------------
  tracked_assets = jsondecode(file("${local.repo_root}/config/tracked_assets.json")).assets

  # All 50 go to CoinMarketCap: 50 ids in one batched call still costs 1 credit.
  tracked_asset_ids = [for a in local.tracked_assets : a.cmc_id]

  # Only the 45 with a live Binance pair go to the producer. The other five are
  # not an oversight -- USDT cannot have a USDT pair, XMR and DAI are delisted
  # tombstones that accept a subscription and then deliver nothing, and HYPE and
  # KAS were never listed. has_stream is a flag the code READS, never an
  # assumption it makes. See data_sources.md section 6.
  streamed_symbols = [for a in local.tracked_assets : a.binance_symbol if a.has_stream]
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
# Network -- the minimum VPC the Fargate producer needs (Phase 5).
#
# The first VPC in the project: everything before it (Lambda, Glue, Step
# Functions, Athena) runs outside one. No NAT Gateway, on purpose -- the
# producer only dials out, and a NAT would cost ~$33/month to buy nothing.
# Every resource in this module is free.
# -----------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  environment = var.environment
}

# -----------------------------------------------------------------------------
# Ingestion -- both paths into bronze:
#   - the CoinMarketCap extractor Lambda and its schedule (Phase 3)
#   - the Binance stream: Kinesis, Firehose and the Fargate producer (Phase 5)
#
# The streaming half is gated on streaming_enabled, which defaults to false. A
# Kinesis shard bills from creation rather than from use, so dormancy here has
# to mean "does not exist", not "sits idle". See "Current state: DORMANT".
# -----------------------------------------------------------------------------
module "ingestion" {
  source = "../../modules/ingestion"

  environment         = var.environment
  aws_account_id      = var.aws_account_id
  aws_region          = var.aws_region
  bronze_bucket_id    = module.storage.bronze_bucket_id
  bronze_bucket_arn   = module.storage.bronze_bucket_arn
  bronze_prefix       = var.bronze_prefix
  secrets_manager_arn = var.secrets_manager_arn
  tracked_asset_ids   = local.tracked_asset_ids
  schedule_expression = var.eventbridge_schedule_expression
  rule_enabled        = var.eventbridge_rule_enabled

  lambda_source_file = "${local.repo_root}/extractor_bronze_lambda/app.py"
  lambda_build_path  = "${local.repo_root}/extractor_bronze_lambda/build/cmc_extractor.zip"

  # --- streaming path -------------------------------------------------------
  streaming_enabled       = var.streaming_enabled
  streamed_symbols        = local.streamed_symbols
  bronze_streaming_prefix = var.bronze_streaming_prefix

  public_subnet_ids          = module.network.public_subnet_ids
  producer_security_group_id = module.network.producer_security_group_id
}

# -----------------------------------------------------------------------------
# Catalog -- Glue databases, the projected Silver tables, the Athena workgroup.
# Phase 6 deleted the Silver crawler; nothing here starts one any more.
# -----------------------------------------------------------------------------
module "catalog" {
  source = "../../modules/catalog"

  project     = var.project
  environment = var.environment
  tags        = var.tags

  silver_bucket_id        = module.storage.silver_bucket_id
  silver_prefix           = var.silver_prefix
  silver_streaming_prefix = var.silver_streaming_prefix

  # Phase 6: silver_bucket_arn is gone from this list. It existed only to scope
  # the Silver crawler's read policy, and the crawler is gone.
  streaming_projection_start_date = var.streaming_projection_start_date

  # Phase 7: the Gold catalog moved out of the hand-run sql/ files and into this
  # module, and the backfill needs its own, much earlier projection floor. The
  # two lists below are what stops the enum projections from drifting away from
  # the universe -- the DDL they replace still named the pre-Phase-4 eleven ids.
  backfill_projection_start_date = var.backfill_projection_start_date
  tracked_asset_ids              = local.tracked_asset_ids
  streamed_symbols               = local.streamed_symbols

  gold_bucket_id              = module.storage.gold_bucket_id
  gold_features_prefix        = var.gold_features_prefix
  gold_ohlc_prefix            = var.gold_ohlc_prefix
  gold_market_features_prefix = var.gold_market_features_prefix
  gold_ml_prefix              = var.gold_ml_prefix

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

  # Phase 6: the Binance stream's own way through Silver. Same buckets, same
  # execution role, different source -- Silver stays source-separated and the
  # join happens in Gold (data_sources.md section 10).
  bronze_streaming_prefix = var.bronze_streaming_prefix
  silver_streaming_prefix = var.silver_streaming_prefix

  gold_bucket_id       = module.storage.gold_bucket_id
  gold_bucket_arn      = module.storage.gold_bucket_arn
  gold_features_prefix = var.gold_features_prefix
  gold_ml_prefix       = var.gold_ml_prefix
  gold_ohlc_prefix     = var.gold_ohlc_prefix

  artifacts_bucket_id  = module.storage.artifacts_bucket_id
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn

  # Phase 7 -- the backfill and the feature layer.
  bronze_backfill_prefix      = var.bronze_backfill_prefix
  backfill_manifest_prefix    = var.backfill_manifest_prefix
  gold_market_features_prefix = var.gold_market_features_prefix
  feature_block_version       = var.feature_block_version
  label_horizon_min           = var.label_horizon_min
  label_threshold_bps         = var.label_threshold_bps

  # The same file this root module reads for the id and symbol lists above,
  # uploaded so the jobs read it too. One owner per fact, across the process
  # boundary: Terraform decides which partitions Athena projects from this file,
  # and the backfill decides which months to download from the same bytes.
  tracked_assets_file = "${local.repo_root}/config/tracked_assets.json"

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

  silver_job_name         = module.processing.silver_job_name
  silver_binance_job_name = module.processing.silver_binance_job_name
  gold_features_job_name  = module.processing.gold_features_job_name
  gold_ohlc_job_name      = module.processing.gold_ohlc_job_name
  gold_ml_job_name        = module.processing.gold_ml_job_name

  # Phase 7. Deliberately absent: the backfill job and the Silver archive job.
  # Both are one-time loads, and the Step Functions role is scoped by ARN, so
  # leaving them out is what makes "the nightly run cannot start them" true
  # rather than merely intended.
  gold_market_features_job_name = module.processing.gold_market_features_job_name

  # Phase 6 dropped silver_crawler_name and added this. The two modules now
  # reference each other -- orchestration reads the topic ARN, observability
  # reads the state machine ARN -- which is fine: Terraform's graph is built
  # over RESOURCES, not modules, and the topic, the machine and the failure
  # rule form a chain, not a cycle.
  sns_topic_arn = module.observability.alerts_topic_arn

  daily_schedule_cron    = var.sfn_daily_schedule_cron
  daily_schedule_enabled = var.sfn_daily_schedule_enabled
}

# -----------------------------------------------------------------------------
# ML -- the durable half of the model lifecycle (Phase 8): the SageMaker
# execution role and the training image repository.
#
# The training JOB is not here and is not a Terraform resource. It is an
# execution, not a desired state; ml/training/launch_training.py owns it. Same
# boundary Phase 7 drew around the backfill.
# -----------------------------------------------------------------------------
module "ml" {
  source = "../../modules/ml"

  project     = var.project
  environment = var.environment
  tags        = var.tags

  gold_bucket_arn = module.storage.gold_bucket_arn
  gold_ml_prefix  = var.gold_ml_prefix

  artifacts_bucket_arn = module.storage.artifacts_bucket_arn
  artifacts_bucket_id  = module.storage.artifacts_bucket_id
  ml_code_prefix       = var.ml_code_prefix
  ml_model_prefix      = var.ml_model_prefix
}

# -----------------------------------------------------------------------------
# Observability -- failure detection and alerting.
# -----------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  environment       = var.environment
  sns_email         = var.sns_email
  state_machine_arn = module.orchestration.state_machine_arn

  # Phase 5: a cost guard, in place BEFORE the streaming gate is ever opened.
  monthly_budget_usd = var.monthly_budget_usd
}
