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
