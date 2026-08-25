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

# --- Catalog ----------------------------------------------------------------
output "glue_databases" {
  description = "Glue catalog databases backing the Silver and Gold tables."
  value = {
    silver = module.catalog.silver_database_name
    gold   = module.catalog.gold_database_name
  }
}

output "athena_workgroup" {
  description = "Athena workgroup enforcing the shared result location and SSE."
  value       = module.catalog.athena_workgroup_name
}

# --- Processing -------------------------------------------------------------
output "glue_jobs" {
  description = "The four ETL jobs, in the order the state machine runs them."
  value = [
    module.processing.silver_job_name,
    module.processing.gold_features_job_name,
    module.processing.gold_ohlc_job_name,
    module.processing.gold_ml_job_name,
  ]
}

# --- Orchestration & alerting ----------------------------------------------
output "state_machine_arn" {
  description = "ARN of the daily Gold pipeline state machine."
  value       = module.orchestration.state_machine_arn
}

output "alerts_topic_arn" {
  description = "SNS topic carrying pipeline failure alerts."
  value       = module.observability.alerts_topic_arn
}
