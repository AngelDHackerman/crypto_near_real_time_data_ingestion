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