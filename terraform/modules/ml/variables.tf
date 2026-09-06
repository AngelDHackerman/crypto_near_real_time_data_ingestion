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

# --- Phase 10 ----------------------------------------------------------------
variable "serving_enabled" {
  description = <<-EOT
    Gate for the whole serving path: the model, the endpoint configuration, the
    endpoint and the inference Lambda.

    Unlike streaming_enabled, this gate protects the APPLY before it protects
    the bill. An aws_sagemaker_model needs a real model artifact, so with no
    training run behind it `true` fails the apply rather than creating something
    expensive. It also needs the DuckDB Lambda layer to have been built --
    serving/inference/build_layer.sh -- because the layer is ~20 MB and is built
    rather than committed.

    Serverless inference costs $0 at rest and bills per request, so opening this
    gate does not start a recurring bill the way streaming_enabled does.
  EOT
  type        = bool
  default     = false
}

variable "model_package_arn" {
  description = "Registry version to deploy. From ml/registry/promote_model.py, never a hand-copied S3 URI -- deploying a registry version is what keeps the served model's metrics recoverable."
  type        = string
  default     = ""
}

variable "serving_memory_mb" {
  description = "Serverless inference memory. Billed per GB-second of actual inference, so over-provisioning costs on every request rather than once."
  type        = number
  default     = 2048
}

variable "serving_max_concurrency" {
  description = "Serverless concurrency ceiling. One: a demonstration endpoint with one caller, where a higher ceiling would not make a request faster and would raise a runaway loop's blast radius from slow to expensive."
  type        = number
  default     = 1
}

variable "silver_bucket_arn" {
  description = "ARN of the silver bucket. The inference Lambda reads the last ~2 days of klines from it and nothing else."
  type        = string
}

variable "silver_bucket_id" {
  description = "Name of the silver bucket, for the Lambda's environment."
  type        = string
}

variable "silver_klines_prefix" {
  description = "Prefix of the Binance klines dataset inside the silver bucket, e.g. binance/klines."
  type        = string
}

variable "feature_columns_key" {
  description = "Key of the ordered feature list the training job wrote beside the model. Feature ORDER is part of an XGBoost model's interface, so serving reads this rather than reconstructing it."
  type        = string
  default     = "ml/models/current/feature_columns.json"
}

variable "inference_lookback_hours" {
  description = "Hours of klines the Lambda pulls per request. The longest window in indicators.sql spans 1440 minutes, so this must exceed 24 -- 50 leaves room for gaps without doubling the objects fetched."
  type        = number
  default     = 50
}

variable "duckdb_layer_dir" {
  description = "Directory populated by serving/inference/build_layer.sh, zipped into the Lambda layer. Built rather than committed: ~61 MB unpacked."
  type        = string
  default     = ""
}

variable "duckdb_version" {
  description = "DuckDB version in the layer. Pinned to the version the tests run against -- a serving engine on a different version than the tested one is training/serving skew with extra steps."
  type        = string
  default     = "1.2.2"
}

variable "inference_source_dir" {
  description = "Directory holding handler.py and feature_request.py."
  type        = string
  default     = ""
}

variable "indicator_sql_module_path" {
  description = "Path to indicator_sql.py, shipped beside the handler. The same module the Glue job gets via --extra-py-files and the tests import directly -- one owner for the window definitions across all three."
  type        = string
  default     = ""
}

variable "inference_build_path" {
  description = "Where the inference Lambda zip is written."
  type        = string
  default     = ""
}
