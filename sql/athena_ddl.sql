CREATE DATABASE IF NOT EXISTS crypto_gold_db;

CREATE EXTERNAL TABLE IF NOT EXISTS crypto_gold_db.features_base (
  asset_id int,
  event_time_utc timestamp,
  symbol string,
  name string,
  source string,
  ingestion_ts_utc timestamp,
  price_usd double,
  market_cap double,
  market_cap_dominance double,
  fully_diluted_market_cap double,
  circulating_supply double,
  max_supply double,
  volume_24h double,
  volume_change_24h double,
  pct_change_1h double,
  pct_change_24h double,
  pct_change_7d double,
  pct_change_30d double,
  pct_change_60d double,
  pct_change_90d double,
  turnover_24h double,
  market_cap_check_gap_pct double
)
PARTITIONED BY (
  dt date,
  asset_id int
)
STORED AS PARQUET
LOCATION 's3://<gold-bucket>/<gold-features-prefix>/';
