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
