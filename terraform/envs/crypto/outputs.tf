# =============================================================================
# Outputs  (roadmap.md, Phase 3 -- there were none before)
#
# These exist to be read by a human and by future phases, not to be wired into
# another config: `terraform output` answers "what is deployed and where" without
# opening the AWS console or the state file.
#
# The state bucket is deliberately absent. Nothing downstream should ever
# discover it programmatically -- see the standing rule in tfstate.tf.
# =============================================================================

output "aws_account_id" {
  description = "Account these resources live in. This account is shared with other projects, so it is worth printing."
  value       = data.aws_caller_identity.current.account_id
}

# --- Storage ----------------------------------------------------------------
output "lake_buckets" {
  description = "The four lake buckets, by layer."
  value = {
    bronze    = module.storage.bronze_bucket_id
    silver    = module.storage.silver_bucket_id
    gold      = module.storage.gold_bucket_id
    artifacts = module.storage.artifacts_bucket_id
  }
}

# --- Ingestion --------------------------------------------------------------
output "extractor_lambda_name" {
  description = "The CMC extractor Lambda."
  value       = module.ingestion.lambda_function_name
}

output "ingestion_enabled" {
  description = "Whether the extractor's EventBridge rule is enabled. False means the project is dormant on purpose (roadmap.md, \"Current state\")."
  value       = var.eventbridge_rule_enabled
}

# --- Streaming (Phase 5) ----------------------------------------------------
output "streaming_enabled" {
  description = "Whether the BILLABLE streaming resources exist. False means the Kinesis stream and its Firehose are not merely idle -- they do not exist, because a shard bills from creation. The producer service is at desired_count = 0."
  value       = var.streaming_enabled
}

output "producer_ecr_repository_url" {
  description = "Push target for the producer image. See producer/Dockerfile for the build and push commands."
  value       = module.ingestion.producer_ecr_repository_url
}

output "producer_service_name" {
  description = "ECS service running the Binance producer. At desired_count = 0 while dormant."
  value       = module.ingestion.producer_service_name
}

output "kinesis_stream_name" {
  description = "Name the Binance tick stream WILL have. Composed, not read: while streaming_enabled is false the stream does not exist, and this output still answers \"what would it be called\"."
  value       = module.ingestion.kinesis_stream_name
}

output "monthly_budget_usd" {
  description = "Account-wide budget threshold now watching, so it is in place before the streaming gate is ever opened."
  value       = var.monthly_budget_usd
}

# --- Catalog ----------------------------------------------------------------
output "glue_databases" {
  description = "Glue catalog databases backing the Silver and Gold tables."
  value = {
    silver = module.catalog.silver_database_name
    gold   = module.catalog.gold_database_name
  }
}

output "silver_tables" {
  description = "The Silver tables, partition-projected rather than crawled since Phase 6. They are queryable the moment Spark writes a partition; nothing has to run first."
  value       = module.catalog.silver_table_names
}

output "athena_workgroup" {
  description = "Athena workgroup enforcing the shared result location and SSE."
  value       = module.catalog.athena_workgroup_name
}

# --- Processing -------------------------------------------------------------
output "glue_jobs" {
  description = "The five ETL jobs, in the order the state machine runs them. Phase 6 added the Binance stream's Silver job."
  value = [
    module.processing.silver_job_name,
    module.processing.silver_binance_job_name,
    module.processing.gold_features_job_name,
    module.processing.gold_ohlc_job_name,
    module.processing.gold_ml_job_name,
  ]
}

# --- Orchestration & alerting ----------------------------------------------
output "daily_pipeline_enabled" {
  description = "Whether the daily Silver -> Gold schedule is ENABLED. False means dormant. Phase 6 gave this rule an explicit gate; before that its state was set in the console and asserted nowhere in code."
  value       = var.sfn_daily_schedule_enabled
}

output "state_machine_arn" {
  description = "ARN of the daily Gold pipeline state machine."
  value       = module.orchestration.state_machine_arn
}

output "alerts_topic_arn" {
  description = "SNS topic carrying pipeline failure alerts."
  value       = module.observability.alerts_topic_arn
}

# --- Phase 8 -----------------------------------------------------------------
output "sagemaker_execution_role_arn" {
  description = "Role the training job assumes. Feed to ml/training/launch_training.py --role-arn."
  value       = module.ml.sagemaker_execution_role_arn
}

output "training_data_uri" {
  description = "The labelled dataset the training job reads. --training-data-uri."
  value       = "s3://${module.storage.gold_bucket_id}/${var.gold_ml_prefix}/"
}

output "model_output_uri" {
  description = "Where model artifacts land."
  value       = module.ml.model_output_uri
}

output "training_image_repository_url" {
  description = "ECR repository for the training image. Empty until Phase 12, and referenced by nothing until then -- deliberately, so it cannot become the wake-up blocker Phase 5's empty repository did."
  value       = module.ml.training_image_repository_url
}
