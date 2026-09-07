variable "project" {
  description = "Project name. Prefixes the SageMaker role and the training ECR repository."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
}

variable "gold_bucket_arn" {
  description = "ARN of the gold bucket. The execution role reads the training dataset from it and can touch nothing else in the lake."
  type        = string
}

variable "gold_ml_prefix" {
  description = "Prefix of the labelled training set inside the gold bucket."
  type        = string
}

variable "artifacts_bucket_arn" {
  description = "ARN of the artifacts bucket, which holds the training code and the model artifacts. Not lake data, so not a medallion bucket -- the standing rule since Phase 2.1."
  type        = string
}

variable "artifacts_bucket_id" {
  description = "Name of the artifacts bucket, for the output S3 URIs published as module outputs."
  type        = string
}

variable "ml_code_prefix" {
  description = "Prefix in artifacts where launch_training.py uploads the packaged source directory, keyed by training job name so a model's lineage stays fetchable."
  type        = string
}

variable "ml_model_prefix" {
  description = "Prefix in artifacts where SageMaker writes model artifacts."
  type        = string
}
