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

variable "silver_binance_job_name" {
  description = "Name of the Binance stream Silver Glue job to start (roadmap.md, Phase 6). Comes from module.processing."
  type        = string
}

variable "sns_topic_arn" {
  description = "Topic the NotifyFailure state publishes to. Comes from module.observability, which owns the topic -- the same one-owner-per-fact rule the job names follow."
  type        = string
}

variable "daily_schedule_cron" {
  description = "EventBridge cron (UTC) driving the daily Silver -> Gold run."
  type        = string
}

variable "daily_schedule_enabled" {
  description = "Whether the daily pipeline's EventBridge rule is ENABLED. False while the project is dormant. Added in Phase 6: this rule starts five Glue jobs and had no gate in code at all, so its dormancy lived only in the console."
  type        = bool
  default     = false
}

variable "gold_market_features_job_name" {
  description = "Name of the 1-minute feature Glue job (roadmap.md, Phase 7). Runs after the OHLC job and before the ML training set, because the labelled rows are built from its output."
  type        = string
}
