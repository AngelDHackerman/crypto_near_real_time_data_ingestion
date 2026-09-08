output "sagemaker_execution_role_arn" {
  description = "Role the training job assumes. Pass to launch_training.py --role-arn."
  value       = aws_iam_role.sagemaker_execution.arn
}

output "training_image_repository_url" {
  description = "ECR repository for the training image. Empty until Phase 12 builds and pushes into it, and deliberately referenced by nothing until then."
  value       = aws_ecr_repository.model_training.repository_url
}

output "model_output_uri" {
  description = "Where SageMaker writes model artifacts."
  value       = "s3://${var.artifacts_bucket_id}/${var.ml_model_prefix}/"
}

output "training_code_uri" {
  description = "Where the packaged training source directory is uploaded, one prefix per training job."
  value       = "s3://${var.artifacts_bucket_id}/${var.ml_code_prefix}/"
}

# --- Phase 9 -----------------------------------------------------------------
output "model_package_group_name" {
  description = "The model registry group. Pass to register_model.py and promote_model.py."
  value       = aws_sagemaker_model_package_group.signal_model.model_package_group_name
}

output "model_promotion_policy_arn" {
  description = "IAM policy granting exactly what the registry scripts call. Attached to nothing until Phase 12's CI role exists -- guessing that role's trust policy now would be worse than leaving it unattached."
  value       = aws_iam_policy.model_promotion.arn
}

# --- Phase 10 alarm targets ---------------------------------------------------
output "endpoint_name" {
  description = "SageMaker endpoint name, or empty while serving is gated off. modules/observability gates its alarms on the same flag, so the alarm cannot outlive the endpoint."
  value       = var.serving_enabled ? aws_sagemaker_endpoint.signal[0].name : ""
}

output "inference_function_name" {
  description = "Inference Lambda name, or empty while serving is gated off."
  value       = var.serving_enabled ? aws_lambda_function.inference[0].function_name : ""
}
