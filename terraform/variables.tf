variable "aws_region" {
  description = "AWS Region"
  type = string
}
variable "environment" {
  description = "environment name"
  type = string
}
variable "secrets_manager_arn" {
  description = "secrets manager"
  type = string
}
variable "secrets_manager_name" {
  description = "secrets manager name"
  type = string
}
variable "bucket_lake_raw_name" {
  description = "Lake Raw Bucket Name"
  type = string
}
variable "bronze_prefix" {
  description = "prefix for bronze data"  
  type = string
}
variable "top10_list_symbol" {
  description = "An array of coins I want to record"
  type = list(string)
}
variable "top10_list_id" {
  description = "Id of the coins to record"
  type = list(number)
}
variable "eventbridge_schedule_expression" {
  description = "Cron expression to trigger ETL/Lambda"
  type        = string
  default     = "rate(5 minutes)"
}

variable "eventbridge_rule_enabled" {
  description = "Enable/Disable EventBridge rule"
  type        = bool
  default     = true
}

variable "bucket_silver_gold_name" {
  description = "Bucket for the silver/gold data"
  type = string
}

variable "bucket_artifacts_name" {
  description = "code for glue job"
  type = string
}

variable "silver_prefix" {
  description = "prefix for silver data"
  type = string
}

variable "gold_prefix" {
  description = "prefix for gold data"
  type = string
}

variable "project" {
  description = "Project tag/name"
  type        = string
  default     = "near-real-time-crypto"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {
    Owner   = "angel"
    Purpose = "crypto-near-rt"
  }
}

variable "athena_results_prefix" {
  description = "output bucket prefix"
  type = string
}
variable "gold_feature_prefix" {
  description = "feature base for gold data"
  type = string
}
variable "gold_ml_prefix" {
  description = "prefix for Machine learning training data"
  type = string
}
variable "gold_ohlcv_prefix" {
  description = "prefix for OHLCV"
  type = string
}

variable "gold_job_name" {
  type        = string
  default     = "gold-features-base"
}
variable "glue_version" {
  type        = string
  default     = "4.0" # cámbialo a "5.0" si usas Glue 5
}
variable "glue_worker_type" {
  type        = string
  default     = "G.1X"
}
variable "glue_number_of_workers" {
  type        = number
  default     = 2
}

# Prefijos para Spark UI y TempDir dentro del bucket GOLD
variable "gold_spark_ui_prefix" {
  type        = string
  default     = "top10/_spark_ui/gold_features_base"
}