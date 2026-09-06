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

# --- Phase 6: the Binance streaming path through Silver -----------------------

variable "bronze_streaming_prefix" {
  description = "Top-level prefix in bronze holding the Binance stream. Input to the Binance Silver job. Its `year=/month=/day=/hour=` levels are ARRIVAL time, not event time -- see the decision block in modules/ingestion/streaming.tf."
  type        = string
}

variable "silver_streaming_prefix" {
  description = "Top-level prefix in silver for the Binance stream. The SOURCE, not the layer, same rule as silver_prefix. The job writes two datasets underneath it: trades/ and klines/."
  type        = string
}

# --- Phase 7 -----------------------------------------------------------------
variable "bronze_backfill_prefix" {
  description = <<-EOT
    Top-level prefix in bronze for the downloaded Binance kline archive.

    A SIBLING of `binance/`, never a child of it, and that is a correctness
    constraint rather than a preference. The streaming Silver job reads
    `binance/` RECURSIVELY as newline-delimited JSON; a CSV placed underneath it
    would be handed to a JSON parser, which does not fail loudly so much as it
    yields a frame of nulls.
  EOT
  type        = string
}

variable "backfill_manifest_prefix" {
  description = "Prefix in the artifacts bucket where each backfill run writes its manifest -- every file, its published SHA-256, its row count and its detected timestamp unit. In artifacts and not bronze because a manifest is not lake data, and because it would break Spark's symbol=/month= partition discovery on the way back out."
  type        = string
}

variable "gold_market_features_prefix" {
  description = "Dataset prefix for the 1-minute feature table."
  type        = string
}

variable "tracked_assets_file" {
  description = "Path to config/tracked_assets.json, uploaded to artifacts so the jobs read the same frozen universe Terraform reads."
  type        = string
}

variable "feature_block_version" {
  description = "Stamped on every feature row. Phase 8's baseline metric is only a baseline against a fixed feature definition, so a change to indicators.sql must be a visible change to this value."
  type        = string
}

variable "label_horizon_min" {
  description = "Forward horizon of the training label, in minutes."
  type        = number
}

variable "label_threshold_bps" {
  description = "Basis points the forward return must exceed for a positive label. Defaults to a round-trip taker fee, so the positive class means \"moved enough to have covered its own costs\" rather than merely \"moved up\"."
  type        = number
}
