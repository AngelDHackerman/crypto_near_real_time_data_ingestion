# The state machine starts these jobs by name. Exporting them from the resources
# that own them means the orchestration module cannot drift out of sync with the
# jobs it calls -- the same rule Phase 2.1 applied to bucket names.

output "silver_job_name" {
  description = "Name of the Silver Glue job."
  value       = aws_glue_job.silver_job.name
}

output "gold_features_job_name" {
  description = "Name of the Gold features base Glue job."
  value       = aws_glue_job.gold_features_base.name
}

output "gold_ohlc_job_name" {
  description = "Name of the Gold OHLC Glue job."
  value       = aws_glue_job.gold_ohlc.name
}

output "gold_ml_job_name" {
  description = "Name of the Gold ML training Glue job."
  value       = aws_glue_job.gold_ml_features.name
}

output "silver_role_arn" {
  description = "ARN of the Silver job's execution role."
  value       = aws_iam_role.glue_role.arn
}

output "gold_role_arn" {
  description = "ARN of the shared Gold jobs execution role."
  value       = aws_iam_role.glue_gold_base.arn
}
