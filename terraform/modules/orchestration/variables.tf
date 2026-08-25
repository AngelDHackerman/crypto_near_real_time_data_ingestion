variable "environment" {
  description = "Environment name. Suffixes the Step Functions role and the schedule rule."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the orchestration roles."
  type        = map(string)
}

variable "silver_job_name" {
  description = "Name of the Silver Glue job to start. Comes from module.processing, not from tfvars -- the job resource owns its own name."
  type        = string
}

variable "gold_features_job_name" {
  description = "Name of the Gold features base Glue job to start."
  type        = string
}

variable "gold_ohlc_job_name" {
  description = "Name of the Gold OHLC Glue job to start."
  type        = string
}

variable "gold_ml_job_name" {
  description = "Name of the Gold ML training Glue job to start."
  type        = string
}

variable "silver_crawler_name" {
  description = "Name of the Silver crawler to start and poll. Comes from module.catalog. Phase 6 deletes these states along with the crawler."
  type        = string
}

variable "daily_schedule_cron" {
  description = "EventBridge cron (UTC) driving the daily Silver -> Gold run."
  type        = string
}
