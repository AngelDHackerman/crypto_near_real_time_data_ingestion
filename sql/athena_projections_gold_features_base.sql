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

-- (Opcional) poner la LOCATION con slash final por consistencia
ALTER TABLE crypto_gold_db.gold_features_base
SET LOCATION 's3://crypto-gold-layer-913524903233/gold_features_base/';

-- Activar Partition Projection
ALTER TABLE crypto_gold_db.gold_features_base SET TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.dt.type'='date',
  'projection.dt.range'='2025-09-24,NOW',
  'projection.dt.format'='yyyy-MM-dd',
  'projection.dt.interval'='1',
  'projection.dt.interval.unit'='DAYS',
  'projection.asset_id.type'='integer',
  'projection.asset_id.range'='1,9999',
  'storage.location.template'='s3://crypto-gold-layer-913524903233/gold_features_base/dt=${dt}/asset_id=${asset_id}/'
);
