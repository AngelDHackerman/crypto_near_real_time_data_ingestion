variable "project" {
  description = "Project name. Prefixes the Gold Glue role and policy."
  type        = string
}

variable "environment" {
  description = "Environment name. Suffixes every Glue job name."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the Glue jobs and the Gold role."
  type        = map(string)
}

variable "bronze_bucket_id" {
  description = "Name of the bronze bucket -- input to the Silver job."
  type        = string
}

variable "bronze_bucket_arn" {
  description = "ARN of the bronze bucket, used to scope the Silver job's read policy."
  type        = string
}

variable "bronze_prefix" {
  description = "Top-level prefix inside the bronze bucket -- the SOURCE, not the layer."
  type        = string
}

variable "silver_bucket_id" {
  description = "Name of the silver bucket -- output of the Silver job, input to the Gold jobs."
  type        = string
}

variable "silver_bucket_arn" {
  description = "ARN of the silver bucket."
  type        = string
}

variable "silver_prefix" {
  description = "Top-level prefix inside the silver bucket -- the SOURCE, not the layer."
  type        = string
}

variable "gold_bucket_id" {
  description = "Name of the gold bucket -- output of the three Gold jobs."
  type        = string
}

variable "gold_bucket_arn" {
  description = "ARN of the gold bucket."
  type        = string
}

variable "gold_features_prefix" {
  description = "Dataset prefix for the Gold features base. Gold is source-agnostic -- it IS the join -- so its prefixes are dataset names, not sources."
  type        = string
}

variable "gold_ml_prefix" {
  description = "Dataset prefix for the ML training set."
  type        = string
}

variable "gold_ohlc_prefix" {
  description = "Dataset prefix for the OHLC aggregates."
  type        = string
}

variable "artifacts_bucket_id" {
  description = "Name of the artifacts bucket holding the job scripts and Spark scratch."
  type        = string
}

variable "artifacts_bucket_arn" {
  description = "ARN of the artifacts bucket, used to scope the jobs to jobs/ and tmp/ only."
  type        = string
}

variable "glue_scripts_dir" {
  description = "Path to the directory holding the Glue job sources, resolved by the caller so this module does not have to know the repo layout."
  type        = string
}
