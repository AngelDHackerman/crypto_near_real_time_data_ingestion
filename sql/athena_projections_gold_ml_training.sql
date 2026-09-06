-- ============================================================================
-- SUPERSEDED BY TERRAFORM IN PHASE 7 -- DO NOT RUN THIS FILE.
--
-- These tables are now aws_glue_catalog_table resources in
-- terraform/modules/catalog/gold_tables.tf. Kept as a record of the manual era,
-- and because the drift found while migrating is worth being able to point at:
-- the OHLC projection here still pins asset_id to the pre-Phase-4 list of
-- ELEVEN ids, so 40 of the 50 tracked assets would have been INVISIBLE to
-- Athena rather than missing with an error.
--
-- That is the failure mode partition projection has, and it is the argument for
-- generating these from config/tracked_assets.json instead of typing them.
-- ============================================================================

CREATE EXTERNAL TABLE crypto_gold_db.gold_ml_training(
  symbol               string,
  name                 string,
  y_ret_1d_fwd         double,
  y_up_1d_2pct         int,
  ret_1d               double,
  ret_3d               double,
  ret_7d               double,
  ret_14d              double,
  ret_30d              double,
  sma_5_over_20        double,
  vol_3d               double,
  vol_7d               double,
  vol_14d              double,
  vol_30d              double,
  volume_24h           double,
  vol_chg_1d           double,
  vol_z_14d            double,
  turnover_24h         double,
  market_cap           double,
  market_cap_dominance double,
  mcap_chg_1d          double,
  mcap_dom_chg_1d      double,
  supply_utilization   double,
  ret_mkt_1d           double,
  ret_btc_1d           double,
  rank_mcap            int,
  rank_momentum_7d     int,
  dow                  tinyint,
  is_month_end         boolean,
  missing_7d           bigint,
  missing_30d          bigint
)
PARTITIONED BY (
  dt       date,
  asset_id int
)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION 's3://crypto-gold-layer-913524903233/gold_ml_training/';

-- Activar Partition Projection
ALTER TABLE crypto_gold_db.gold_ml_training SET TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.dt.type'='date',
  'projection.dt.range'='2025-10-01,NOW',
  'projection.dt.format'='yyyy-MM-dd',
  'projection.dt.interval'='1',
  'projection.dt.interval.unit'='DAYS',
  'projection.asset_id.type'='integer',
  'projection.asset_id.range'='1,9999',
  'storage.location.template'='s3://crypto-gold-layer-913524903233/gold_ml_training/dt=${dt}/asset_id=${asset_id}/'
);