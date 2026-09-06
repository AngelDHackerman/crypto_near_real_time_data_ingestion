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

# --- Phase 7 -----------------------------------------------------------------
variable "backfill_projection_start_date" {
  description = <<-EOT
    Lower bound of the `dt` projection on every table that carries backfilled
    history: the Binance klines Silver table and the Gold tables built from it.

    Separate from streaming_projection_start_date on purpose. That one bounds
    tables only the live stream writes, and widening it to 2017 would make
    Athena enumerate nine years of partitions that cannot exist. This one has to
    reach the archive's own floor -- Binance opened in July 2017 and publishes
    nothing earlier (data_sources.md section 11) -- because a row written
    outside a projected range is invisible rather than an error.
  EOT
  type        = string
}

variable "gold_bucket_id" {
  description = "Name of the gold bucket. Composed into each Gold table's location and projection template."
  type        = string
}

variable "gold_features_prefix" {
  description = "Dataset prefix for the CoinMarketCap market-context table."
  type        = string
}

variable "gold_ohlc_prefix" {
  description = "Dataset prefix for the OHLC aggregates."
  type        = string
}

variable "gold_market_features_prefix" {
  description = "Dataset prefix for the 1-minute feature table Phase 8 trains on."
  type        = string
}

variable "gold_ml_prefix" {
  description = "Dataset prefix for the labelled training set."
  type        = string
}

variable "tracked_asset_ids" {
  description = "The frozen CoinMarketCap ids, read from config/tracked_assets.json by the root module. Rendered into the asset_id enum projections so the catalog cannot disagree with the universe -- the hand-written DDL this replaced still listed the pre-Phase-4 eleven."
  type        = list(number)
}

variable "streamed_symbols" {
  description = "The Binance pairs with a live stream, from the same file. Rendered into the symbol enum projection on the two 1-minute Gold tables."
  type        = list(string)
}
