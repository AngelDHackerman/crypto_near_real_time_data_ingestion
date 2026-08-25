# These buckets are the single source of truth for their own names (Phase 2.1).
# Every consumer takes id/arn from here; nothing reconstructs a bucket name from
# a variable, because holding the same name in two places is what made the
# Phase 1 state recovery dangerous.

output "bronze_bucket_id" {
  description = "Name of the bronze bucket -- raw ingested payloads."
  value       = aws_s3_bucket.bronze.id
}

output "bronze_bucket_arn" {
  description = "ARN of the bronze bucket."
  value       = aws_s3_bucket.bronze.arn
}

output "silver_bucket_id" {
  description = "Name of the silver bucket -- cleaned and typed tables."
  value       = aws_s3_bucket.silver.id
}

output "silver_bucket_arn" {
  description = "ARN of the silver bucket."
  value       = aws_s3_bucket.silver.arn
}

output "gold_bucket_id" {
  description = "Name of the gold bucket -- feature and ML datasets."
  value       = aws_s3_bucket.gold.id
}

output "gold_bucket_arn" {
  description = "ARN of the gold bucket."
  value       = aws_s3_bucket.gold.arn
}

output "artifacts_bucket_id" {
  description = "Name of the artifacts bucket -- everything that is not lake data."
  value       = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  description = "ARN of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}
