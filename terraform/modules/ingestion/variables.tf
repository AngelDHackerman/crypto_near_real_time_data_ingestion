variable "environment" {
  description = "Environment name. Suffixes the Lambda function, its role and the EventBridge rule."
  type        = string
}

variable "bronze_bucket_id" {
  description = "Name of the bronze bucket the extractor writes to. Comes from module.storage."
  type        = string
}

variable "bronze_bucket_arn" {
  description = "ARN of the bronze bucket, used to scope the extractor's S3 policy."
  type        = string
}

variable "bronze_prefix" {
  description = "Top-level prefix inside the bronze bucket. This is the SOURCE, not the layer -- the bucket already names the layer."
  type        = string
}

variable "secrets_manager_arn" {
  description = "ARN of the Secrets Manager secret holding the CMC API key, as passed to the Lambda environment."
  type        = string
}

variable "tracked_asset_ids" {
  description = "CoinMarketCap ids to fetch, joined into the TOP_LIST_ID environment variable."
  type        = list(number)
}

variable "schedule_expression" {
  description = "EventBridge schedule expression driving the extractor."
  type        = string
}

variable "rule_enabled" {
  description = "Whether the extractor's EventBridge rule is ENABLED. False while the project is dormant."
  type        = bool
}

variable "lambda_source_file" {
  description = "Path to the extractor's Python entrypoint, resolved by the caller so this module does not have to know the repo layout."
  type        = string
}

variable "lambda_build_path" {
  description = "Path where the built Lambda zip is written."
  type        = string
}
