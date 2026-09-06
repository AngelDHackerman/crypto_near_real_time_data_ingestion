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

CREATE DATABASE IF NOT EXISTS crypto_gold_db;

CREATE EXTERNAL TABLE IF NOT EXISTS crypto_gold_db.gold_ohlc (
  period_start        timestamp,
  start_ts            timestamp,
  end_ts              timestamp,
  n_ticks             int,
  valid_ticks         int,
  open                double,
  high                double,
  low                 double,
  close               double,
  open_market_cap     double,
  high_market_cap     double,
  low_market_cap      double,
  close_market_cap    double
)
PARTITIONED BY (
  g  string,
  dt date,
  asset_id int
)
STORED AS PARQUET
LOCATION 's3://crypto-gold-layer-913524903233/gold_ohlc/'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.g.type'    = 'enum',
  'projection.g.values'  = 'hour,day,week,month',
  'projection.dt.type'          = 'date',
  'projection.dt.format'        = 'yyyy-MM-dd',
  'projection.dt.interval'      = '1',
  'projection.dt.interval.unit' = 'DAYS',
  'projection.dt.range'         = '2025-09-01,NOW',
  'projection.asset_id.type'  = 'integer',
  'projection.asset_id.range' = '1,999999',
  'projection.asset_id.digits' = '1',
  'storage.location.template' =
    's3://crypto-gold-layer-913524903233/gold_ohlc/g=${g}/dt=${dt}/asset_id=${asset_id}/'
);


-- Create the views

CREATE OR REPLACE VIEW crypto_gold_db.gold_ohlc_hour  AS
SELECT * FROM crypto_gold_db.gold_ohlc WHERE g='hour';

CREATE OR REPLACE VIEW crypto_gold_db.gold_ohlc_day   AS
SELECT * FROM crypto_gold_db.gold_ohlc WHERE g='day';

CREATE OR REPLACE VIEW crypto_gold_db.gold_ohlc_week  AS
SELECT * FROM crypto_gold_db.gold_ohlc WHERE g='week';

CREATE OR REPLACE VIEW crypto_gold_db.gold_ohlc_month AS
SELECT * FROM crypto_gold_db.gold_ohlc WHERE g='month';
<

-- 1) Corrige el LOCATION raíz
ALTER TABLE crypto_gold_db.gold_ohlc
SET LOCATION 's3://crypto-gold-layer-913524903233/gold_ohlc/';

-- 2) Corrige el template de proyección
ALTER TABLE crypto_gold_db.gold_ohlc
SET TBLPROPERTIES (
  'storage.location.template' = 's3://crypto-gold-layer-913524903233/gold_ohlc/g=${g}/dt=${dt}/asset_id=${asset_id}/'
);

-- 3) mejorar la particion solo por los ids existentes
ALTER TABLE crypto_gold_db.gold_ohlc
SET TBLPROPERTIES (
  'projection.asset_id.type'   = 'enum',
  'projection.asset_id.values' = '1,1027,52,825,1839,5426,3408,74,2010,1958,1697'
);