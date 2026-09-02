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

# =============================================================================
# Phase 5 -- streaming path (Kinesis + Firehose + the Binance producer)
# =============================================================================

variable "aws_account_id" {
  description = "Account that owns the stream. Used to compose the Kinesis ARN for the producer's IAM policy without depending on the (possibly absent) stream resource."
  type        = string
}

variable "aws_region" {
  description = "Region. Composed into the Kinesis ARN and passed to the container's log driver."
  type        = string
}

variable "streaming_enabled" {
  description = <<-EOT
    THE COST GATE. False while the project is dormant, which is its default state.

    This is a stronger switch than rule_enabled, and the difference is the point:
    a DISABLED EventBridge rule is free, so it may exist while off, but a Kinesis
    shard bills ~$10.95/month from creation at zero traffic. So this drives
    `count` on the stream and Firehose -- they must not exist -- and drives the
    producer service's desired_count to zero. Everything else in the streaming
    path is free to exist and is applied regardless.
  EOT
  type        = bool
  default     = false
}

variable "kinesis_shard_count" {
  description = "Shards. One, decided against measured load: 17.4 KB/s and ~70 records/s against a shard's 1 MB/s and 1,000 records/s -- 60x and 14x headroom. See data_sources.md section 9."
  type        = number
  default     = 1
}

variable "kinesis_retention_hours" {
  description = "Stream retention. 24 h is the free default; longer is billed per shard-hour. Firehose consumes within seconds, so retention here is replay headroom for a failed consumer, not storage."
  type        = number
  default     = 24
}

variable "bronze_streaming_prefix" {
  description = "Top-level prefix in bronze for the Binance stream. The SOURCE, not the layer -- the bucket already names the layer, same rule as bronze_prefix."
  type        = string
  default     = "binance"
}

variable "firehose_buffer_mb" {
  description = "Firehose buffer size in MiB. Whichever of size/interval is hit first triggers a flush."
  type        = number
  default     = 5
}

variable "firehose_buffer_seconds" {
  description = "Firehose buffer interval. 300 s rather than the 60 s minimum: 60 s would write ~1,440 small objects a day, which is the Bronze small-file problem Phase 6 exists to fix. The cost is that bronze lands up to 5 minutes behind the tick."
  type        = number
  default     = 300
}

variable "streamed_symbols" {
  description = "Binance symbols the producer subscribes to. Passed in from config/tracked_assets.json filtered on has_stream, so the producer, the Lambda and the Gold job read one list."
  type        = list(string)
}

variable "binance_stream_types" {
  description = "Per-symbol stream suffixes. aggTrade measured 3.86x fewer frames than trade with no loss at a one-minute grain; kline_1m is what makes the 2017 backfill and the live stream the same table. bookTicker is deliberately absent -- 123.5 msg/s on BTCUSDT alone. See data_sources.md section 9."
  type        = list(string)
  default     = ["aggTrade", "kline_1m"]
}

variable "producer_cpu" {
  description = "Fargate task CPU units. 256 = 0.25 vCPU, the smallest Fargate size, and ~60x the measured need."
  type        = number
  default     = 256
}

variable "producer_memory" {
  description = "Fargate task memory in MiB. 512 is the minimum permitted at 0.25 vCPU."
  type        = number
  default     = 512
}

variable "producer_desired_count" {
  description = "Tasks to run when the gate is open. ONE. A second task means a second WebSocket writing every tick to Kinesis twice, and a duplicate looks like real volume in a way a gap never does."
  type        = number
  default     = 1
}

variable "producer_image_tag" {
  description = "ECR tag the task definition pulls."
  type        = string
  default     = "latest"
}

variable "producer_batch_max_bytes" {
  description = "Bytes to accumulate before a PutRecords call. ~5 KB against Kinesis's 1 KB billing rounding: unbatched, 146-360 byte frames bill ~4x the bytes actually sent."
  type        = number
  default     = 5120
}

variable "producer_batch_max_seconds" {
  description = "Flush the batch after this long even if it is not full, so a quiet symbol is not held indefinitely."
  type        = number
  default     = 5
}

variable "public_subnet_ids" {
  description = "Subnets the producer task runs in. Comes from module.network."
  type        = list(string)
}

variable "producer_security_group_id" {
  description = "Egress-only security group for the producer task. Comes from module.network."
  type        = string
}
