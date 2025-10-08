-- (Opcional) poner la LOCATION con slash final por consistencia
ALTER TABLE crypto_gold_db.gold_features_base
SET LOCATION 's3://lake-curated-data-silver-gold-crypto/top10/gold/gold_features_base/';

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
  'storage.location.template'='s3://lake-curated-data-silver-gold-crypto/top10/gold/gold_features_base/dt=${dt}/asset_id=${asset_id}/'
);
