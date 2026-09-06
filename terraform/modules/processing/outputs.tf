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

output "silver_binance_job_name" {
  description = "Name of the Binance stream Silver Glue job (roadmap.md, Phase 6)."
  value       = aws_glue_job.silver_binance_job.name
}

# --- Phase 7 -----------------------------------------------------------------
output "backfill_job_name" {
  description = "Python shell job that downloads the Binance kline archive into Bronze. Deliberately absent from the state machine: it is started once, by hand, like the wake-up flags."
  value       = aws_glue_job.backfill_binance_klines.name
}

output "silver_binance_backfill_job_name" {
  description = "Spark job that normalises the downloaded archive into the Silver klines table under source=backfill."
  value       = aws_glue_job.silver_binance_backfill.name
}

output "gold_market_features_job_name" {
  description = "Spark job that builds the 1-minute feature table Phase 8 trains on."
  value       = aws_glue_job.gold_market_features.name
}
