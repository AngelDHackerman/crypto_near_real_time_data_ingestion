CREATE EXTERNAL TABLE IF NOT EXISTS crypto_gold_db.ml_training (
  -- identity
  symbol                              string,
  name                                string,

  -- target(s) (shifted forward)
  y_ret_1d_fwd                        double,
  y_up_1d_2pct                        int,

  -- returns & momentum (past only)
  ret_1d                              double,
  ret_3d                              double,
  ret_7d                              double,
  ret_14d                             double,
  ret_30d                             double,
  sma_5_over_20                       double,
  ema_12_over_26                      double,

  -- volatility
  vol_3d                              double,
  vol_7d                              double,
  vol_14d                             double,
  vol_30d                             double,
  vol_ewma_14                         double,

  -- volume & turnover
  volume_24h                          double,
  vol_chg_1d                          double,
  vol_z_14d                           double,
  turnover_24h                        double,

  -- market cap & dominance
  market_cap                          double,
  market_cap_dominance                double,
  mcap_chg_1d                         double,
  mcap_dom_chg_1d                     double,
  supply_utilization                  double,

  -- cross-sectional factors
  ret_mkt_1d                          double,
  ret_btc_1d                          double,
  corr_30d_to_btc                     double,
  rank_mcap                           int,
  rank_momentum_7d                    int,

  -- calendar
  dow                                 tinyint,
  is_month_end                        boolean,

  -- quality flags
  missing_7d                          int,
  missing_30d                         int
)
PARTITIONED BY (
  dt       date,
  asset_id int
)
STORED AS PARQUET
LOCATION 's3://lake-curated-data-silver-gold-crypto/top10/gold/gold_ml_training/';
