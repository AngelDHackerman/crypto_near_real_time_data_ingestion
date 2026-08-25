# =============================================================================
# moved {} blocks -- the whole point of Phase 3  (roadmap.md, Phase 3)
#
# Modularising changes a resource's STATE ADDRESS: aws_s3_bucket.bronze becomes
# module.storage.aws_s3_bucket.bronze. To Terraform that is a delete plus a
# create -- it would destroy the data lake and rebuild it empty. These blocks
# tell it the resource simply moved, so the plan stays at zero diffs and nothing
# is touched in AWS.
#
# This is also why the refactor comes AFTER the Phase 1 import and the Phase 2
# backend migration, not before: it is applied on top of a state that is already
# known-good and remotely versioned.
#
# LIFETIME: these are one-shot. Once applied, the state holds the new addresses
# and the blocks are dead weight. They are removed in a follow-up commit --
# see the DoD in roadmap.md.
#
# 69 relocated addresses. Data sources need no moved block: they are re-read on
# every plan and hold no real infrastructure.
# =============================================================================

# --- module.storage (20) -------------------------------------------

moved {
  from = aws_s3_bucket.bronze
  to   = module.storage.aws_s3_bucket.bronze
}

moved {
  from = aws_s3_bucket.silver
  to   = module.storage.aws_s3_bucket.silver
}

moved {
  from = aws_s3_bucket.gold
  to   = module.storage.aws_s3_bucket.gold
}

moved {
  from = aws_s3_bucket.artifacts
  to   = module.storage.aws_s3_bucket.artifacts
}

moved {
  from = aws_s3_bucket_versioning.bronze
  to   = module.storage.aws_s3_bucket_versioning.bronze
}

moved {
  from = aws_s3_bucket_versioning.silver
  to   = module.storage.aws_s3_bucket_versioning.silver
}

moved {
  from = aws_s3_bucket_versioning.gold
  to   = module.storage.aws_s3_bucket_versioning.gold
}

moved {
  from = aws_s3_bucket_versioning.artifacts
  to   = module.storage.aws_s3_bucket_versioning.artifacts
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.bronze
  to   = module.storage.aws_s3_bucket_server_side_encryption_configuration.bronze
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.silver
  to   = module.storage.aws_s3_bucket_server_side_encryption_configuration.silver
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.gold
  to   = module.storage.aws_s3_bucket_server_side_encryption_configuration.gold
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.artifacts
  to   = module.storage.aws_s3_bucket_server_side_encryption_configuration.artifacts
}

moved {
  from = aws_s3_bucket_public_access_block.bronze
  to   = module.storage.aws_s3_bucket_public_access_block.bronze
}

moved {
  from = aws_s3_bucket_public_access_block.silver
  to   = module.storage.aws_s3_bucket_public_access_block.silver
}

moved {
  from = aws_s3_bucket_public_access_block.gold
  to   = module.storage.aws_s3_bucket_public_access_block.gold
}

moved {
  from = aws_s3_bucket_public_access_block.artifacts
  to   = module.storage.aws_s3_bucket_public_access_block.artifacts
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.bronze
  to   = module.storage.aws_s3_bucket_lifecycle_configuration.bronze
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.silver
  to   = module.storage.aws_s3_bucket_lifecycle_configuration.silver
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.gold
  to   = module.storage.aws_s3_bucket_lifecycle_configuration.gold
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.artifacts
  to   = module.storage.aws_s3_bucket_lifecycle_configuration.artifacts
}

# --- module.ingestion (12) -----------------------------------------

moved {
  from = aws_secretsmanager_secret.near_real_time_crypto
  to   = module.ingestion.aws_secretsmanager_secret.near_real_time_crypto
}

moved {
  from = aws_lambda_function.fetch_top10_crypto
  to   = module.ingestion.aws_lambda_function.fetch_top10_crypto
}

moved {
  from = aws_cloudwatch_log_group.lambda_logs
  to   = module.ingestion.aws_cloudwatch_log_group.lambda_logs
}

moved {
  from = aws_iam_role.lambda_role
  to   = module.ingestion.aws_iam_role.lambda_role
}

moved {
  from = aws_iam_role_policy_attachment.lambda_logs
  to   = module.ingestion.aws_iam_role_policy_attachment.lambda_logs
}

moved {
  from = aws_iam_policy.lambda_s3_rw_bronze
  to   = module.ingestion.aws_iam_policy.lambda_s3_rw_bronze
}

moved {
  from = aws_iam_role_policy_attachment.lambda_s3_rw_attach
  to   = module.ingestion.aws_iam_role_policy_attachment.lambda_s3_rw_attach
}

moved {
  from = aws_iam_policy.lambda_read_secret
  to   = module.ingestion.aws_iam_policy.lambda_read_secret
}

moved {
  from = aws_iam_role_policy_attachment.attach_lambda_read_secret
  to   = module.ingestion.aws_iam_role_policy_attachment.attach_lambda_read_secret
}

moved {
  from = aws_cloudwatch_event_rule.extractor_schedule
  to   = module.ingestion.aws_cloudwatch_event_rule.extractor_schedule
}

moved {
  from = aws_cloudwatch_event_target.extractor_target
  to   = module.ingestion.aws_cloudwatch_event_target.extractor_target
}

moved {
  from = aws_lambda_permission.allow_eventbridge_invoke
  to   = module.ingestion.aws_lambda_permission.allow_eventbridge_invoke
}

# --- module.catalog (8) --------------------------------------------

moved {
  from = aws_glue_catalog_database.silver_db
  to   = module.catalog.aws_glue_catalog_database.silver_db
}

moved {
  from = aws_glue_catalog_database.gold_db
  to   = module.catalog.aws_glue_catalog_database.gold_db
}

moved {
  from = aws_glue_crawler.silver_crawler
  to   = module.catalog.aws_glue_crawler.silver_crawler
}

moved {
  from = aws_iam_role.glue_crawler_role
  to   = module.catalog.aws_iam_role.glue_crawler_role
}

moved {
  from = aws_iam_policy.glue_crawler_policy
  to   = module.catalog.aws_iam_policy.glue_crawler_policy
}

moved {
  from = aws_iam_role_policy_attachment.attach_service_role
  to   = module.catalog.aws_iam_role_policy_attachment.attach_service_role
}

moved {
  from = aws_iam_role_policy_attachment.attach_custom
  to   = module.catalog.aws_iam_role_policy_attachment.attach_custom
}

moved {
  from = aws_athena_workgroup.workgroup
  to   = module.catalog.aws_athena_workgroup.workgroup
}

# --- module.processing (14) ----------------------------------------

moved {
  from = aws_iam_role.glue_role
  to   = module.processing.aws_iam_role.glue_role
}

moved {
  from = aws_iam_role_policy_attachment.glue_service
  to   = module.processing.aws_iam_role_policy_attachment.glue_service
}

moved {
  from = aws_iam_role_policy.glue_s3_inline
  to   = module.processing.aws_iam_role_policy.glue_s3_inline
}

moved {
  from = aws_glue_job.silver_job
  to   = module.processing.aws_glue_job.silver_job
}

moved {
  from = aws_iam_role.glue_gold_base
  to   = module.processing.aws_iam_role.glue_gold_base
}

moved {
  from = aws_iam_policy.glue_gold_policy
  to   = module.processing.aws_iam_policy.glue_gold_policy
}

moved {
  from = aws_iam_role_policy_attachment.glue_gold_attach
  to   = module.processing.aws_iam_role_policy_attachment.glue_gold_attach
}

moved {
  from = aws_glue_job.gold_features_base
  to   = module.processing.aws_glue_job.gold_features_base
}

moved {
  from = aws_glue_job.gold_ohlc
  to   = module.processing.aws_glue_job.gold_ohlc
}

moved {
  from = aws_glue_job.gold_ml_features
  to   = module.processing.aws_glue_job.gold_ml_features
}

moved {
  from = aws_s3_object.silver_glue_script
  to   = module.processing.aws_s3_object.silver_glue_script
}

moved {
  from = aws_s3_object.gold_features_base_glue_script
  to   = module.processing.aws_s3_object.gold_features_base_glue_script
}

moved {
  from = aws_s3_object.gold_ml_training_glue_script
  to   = module.processing.aws_s3_object.gold_ml_training_glue_script
}

moved {
  from = aws_s3_object.gold_ohlc_glue_script
  to   = module.processing.aws_s3_object.gold_ohlc_glue_script
}

# --- module.orchestration (10) -------------------------------------

moved {
  from = aws_sfn_state_machine.daily_gold_pipeline
  to   = module.orchestration.aws_sfn_state_machine.daily_gold_pipeline
}

moved {
  from = aws_cloudwatch_log_group.sfn_logs
  to   = module.orchestration.aws_cloudwatch_log_group.sfn_logs
}

moved {
  from = aws_iam_role.sfn_role
  to   = module.orchestration.aws_iam_role.sfn_role
}

moved {
  from = aws_iam_policy.sfn_policy
  to   = module.orchestration.aws_iam_policy.sfn_policy
}

moved {
  from = aws_iam_role_policy_attachment.sfn_attach
  to   = module.orchestration.aws_iam_role_policy_attachment.sfn_attach
}

moved {
  from = aws_cloudwatch_event_rule.daily_gold_silver
  to   = module.orchestration.aws_cloudwatch_event_rule.daily_gold_silver
}

moved {
  from = aws_iam_role.events_to_sfn_role
  to   = module.orchestration.aws_iam_role.events_to_sfn_role
}

moved {
  from = aws_iam_policy.events_to_sfn_policy
  to   = module.orchestration.aws_iam_policy.events_to_sfn_policy
}

moved {
  from = aws_iam_role_policy_attachment.events_to_sfn_attach
  to   = module.orchestration.aws_iam_role_policy_attachment.events_to_sfn_attach
}

moved {
  from = aws_cloudwatch_event_target.daily_gold_target
  to   = module.orchestration.aws_cloudwatch_event_target.daily_gold_target
}

# --- module.observability (5) --------------------------------------

moved {
  from = aws_sns_topic.sfn_alerts
  to   = module.observability.aws_sns_topic.sfn_alerts
}

moved {
  from = aws_sns_topic_subscription.sfn_alerts_email
  to   = module.observability.aws_sns_topic_subscription.sfn_alerts_email
}

moved {
  from = aws_sns_topic_policy.sfn_alerts_policy
  to   = module.observability.aws_sns_topic_policy.sfn_alerts_policy
}

moved {
  from = aws_cloudwatch_event_rule.sfn_failed
  to   = module.observability.aws_cloudwatch_event_rule.sfn_failed
}

moved {
  from = aws_cloudwatch_event_target.sfn_failed_to_sns
  to   = module.observability.aws_cloudwatch_event_target.sfn_failed_to_sns
}
