variable "project" {
  description = "Project name. Prefixes the Athena workgroup."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the catalog resources."
  type        = map(string)
}

variable "silver_bucket_id" {
  description = "Name of the silver bucket. Composed into each Silver table's location and projection template."
  type        = string
}

variable "silver_prefix" {
  description = "Top-level prefix inside the silver bucket for the CoinMarketCap source -- the SOURCE, not the layer."
  type        = string
}

variable "silver_streaming_prefix" {
  description = "Top-level prefix inside the silver bucket for the Binance stream. The trades/ and klines/ datasets live underneath it."
  type        = string
}

variable "streaming_projection_start_date" {
  description = <<-EOT
    Lower bound of the `dt` partition projection on the two Binance Silver
    tables, as yyyy-MM-dd.

    It is a variable rather than a literal because it is a correctness knob, not
    a formatting one: a row written outside the projected range is INVISIBLE to
    Athena rather than an error, so Phase 7's backfill to 2017 has to widen this
    in the same change that writes those rows.
  EOT
  type        = string
}

variable "artifacts_bucket_id" {
  description = "Name of the artifacts bucket where Athena writes query results."
  type        = string
}

variable "athena_results_prefix" {
  description = "Prefix inside the artifacts bucket for Athena query results."
  type        = string
}
