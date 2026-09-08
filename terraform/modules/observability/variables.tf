variable "environment" {
  description = "Environment name. Suffixes the topic and the failure rule."
  type        = string
}

variable "sns_email" {
  description = "Address subscribed to the alerts topic."
  type        = string
}

variable "state_machine_arn" {
  description = "ARN of the state machine to watch for FAILED / TIMED_OUT / ABORTED executions. Comes from module.orchestration."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly budget in USD. Notifies at 80% forecast and 100% actual, by email directly -- not through the SNS topic, whose policy would silently drop a budgets.amazonaws.com publish."
  type        = number
  default     = 40
}

# --- Phase 11 ----------------------------------------------------------------
variable "name_prefix" {
  description = "Prefix for the alerting resources. Was hardcoded as \"near-real-time-crypto\" in five places before Phase 11 split the topics."
  type        = string
  default     = "near-real-time-crypto"
}

variable "aws_account_id" {
  description = "Account allowed to publish to the topics. Not decoration: a service principal like cloudwatch.amazonaws.com is the CloudWatch SERVICE, everywhere, so an aws:SourceAccount condition is what stops any account's alarms from paging this project's owner."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

variable "slack_enabled" {
  description = <<-EOT
    Whether model signals are delivered to Slack.

    Gated on a CREDENTIAL, not on cost -- a Lambda and a secret are free at
    rest. True with an empty secret creates a subscription that fails on every
    message, surfacing as a Lambda error rather than as "the webhook was never
    pasted". The secret resource is created either way and holds a placeholder;
    a human sets the real value out of band, exactly as with the CoinMarketCap
    key.
  EOT
  type        = bool
  default     = false
}

variable "slack_notifier_source_file" {
  description = "Path to slack_notifier_lambda/app.py."
  type        = string
  default     = ""
}

variable "slack_notifier_build_path" {
  description = "Where the notifier zip is written."
  type        = string
  default     = ""
}

variable "extractor_function_name" {
  description = "CoinMarketCap extractor Lambda, watched for errors. From module.ingestion -- the resource that owns the name."
  type        = string
}

variable "streaming_enabled" {
  description = "Mirrors the ingestion gate. The producer-liveness and Firehose-freshness alarms only exist when the things they watch do, so the alarm count tracks what is actually running rather than what could be."
  type        = bool
  default     = false
}

variable "producer_cluster_name" {
  description = "ECS cluster running the Binance producer."
  type        = string
  default     = ""
}

variable "producer_service_name" {
  description = "ECS service running the Binance producer."
  type        = string
  default     = ""
}

variable "firehose_stream_name" {
  description = "Firehose delivery stream watched for delivery freshness."
  type        = string
  default     = ""
}

variable "serving_enabled" {
  description = "Mirrors the serving gate, for the endpoint and inference-Lambda alarms."
  type        = bool
  default     = false
}

variable "endpoint_name" {
  description = "SageMaker endpoint watched for 5XX and latency."
  type        = string
  default     = ""
}

variable "inference_function_name" {
  description = "Inference Lambda watched for errors."
  type        = string
  default     = ""
}

variable "endpoint_latency_budget_ms" {
  description = "p95 latency budget in milliseconds. The SAME number Phase 9's promotion gate enforces, on purpose: a model that would not be promoted today should not keep serving unnoticed."
  type        = number
  default     = 500
}
