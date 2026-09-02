output "lambda_function_name" {
  description = "Name of the CMC extractor Lambda."
  value       = aws_lambda_function.fetch_top10_crypto.function_name
}

output "lambda_function_arn" {
  description = "ARN of the CMC extractor Lambda."
  value       = aws_lambda_function.fetch_top10_crypto.arn
}

output "lambda_role_arn" {
  description = "ARN of the extractor's execution role."
  value       = aws_iam_role.lambda_role.arn
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret created for the extractor."
  value       = aws_secretsmanager_secret.near_real_time_crypto.arn
}

# --- Phase 5 -- streaming path ----------------------------------------------

output "kinesis_stream_name" {
  description = "Name of the Binance tick stream. Composed from a local, so it is stable whether or not the stream currently exists."
  value       = local.kinesis_stream_name
}

output "kinesis_stream_arn" {
  description = "ARN of the Binance tick stream, composed rather than read -- the resource has count = 0 while the project is dormant."
  value       = local.kinesis_stream_arn
}

output "producer_ecr_repository_url" {
  description = "Push target for the producer image: `docker push <this>:latest`."
  value       = aws_ecr_repository.producer.repository_url
}

output "producer_service_name" {
  description = "Name of the ECS service running the producer."
  value       = aws_ecs_service.producer.name
}

output "producer_log_group_name" {
  description = "CloudWatch log group the producer writes to."
  value       = aws_cloudwatch_log_group.producer.name
}

output "streaming_enabled" {
  description = "Whether the billable streaming resources exist. False while dormant."
  value       = var.streaming_enabled
}
