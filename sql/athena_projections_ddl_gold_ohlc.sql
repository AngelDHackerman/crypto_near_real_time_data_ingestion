CREATE DATABASE IF NOT EXISTS crypto_gold_db;

CREATE EXTERNAL TABLE IF NOT EXISTS crypto_gold_db.ohlc (
  asset_id            int,
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
  g  string,  -- hour|day|week|month
  dt date,
  asset_id int
)
STORED AS PARQUET
LOCATION 's3://lake-curated-data-silver-gold-crypto/top10/gold_ohlc/'
TBLPROPERTIES (
  -- Habilita Partition Projection
  'projection.enabled' = 'true',

  -- g: enum con tus 4 granularidades
  'projection.g.type'    = 'enum',
  'projection.g.values'  = 'hour,day,week,month',

  -- dt: rango de fechas dinámico (ajusta la fecha inicial a tu historico real)
  'projection.dt.type'          = 'date',
  'projection.dt.format'        = 'yyyy-MM-dd',
  'projection.dt.interval'      = '1',
  'projection.dt.interval.unit' = 'DAYS',
  -- Comienza cuando arrancó tu pipeline; 'NOW' cierra en tiempo de consulta
  'projection.dt.range'         = '2025-09-01,NOW',

  -- asset_id: rango entero (ajústalo a tus IDs reales)
  'projection.asset_id.type'  = 'integer',
  'projection.asset_id.range' = '1,999999',
  'projection.asset_id.digits' = '1',

  -- Template que mapea las particiones a la ruta S3 real
  'storage.location.template' =
    's3://lake-curated-data-silver-gold-crypto/top10/gold_ohlc/g=${g}/dt=${dt}/asset_id=${asset_id}/'
);
