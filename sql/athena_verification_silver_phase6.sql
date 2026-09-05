-- =============================================================================
-- Phase 6 verification -- run these at the WAKE-UP, not before.
--
-- Phase 6's last DoD line is "Athena queries return the same results as before
-- the migration", and it is the one line that could not be closed when the
-- phase was written: the lake is empty (Phase 2.1 deleted it), the pipeline is
-- dormant, and there is no "before" to compare against. Pretending otherwise
-- would have been the one thing worse than leaving it open.
--
-- So this file is the check itself, written down while the reasoning is fresh
-- rather than reconstructed months later. Every query below has a stated
-- expected answer; a run where all of them pass is what closes that line.
--
-- NOTE ON WHERE THE DDL LIVES. These tables are NOT created by this file.
-- Phase 6 made them Terraform resources in modules/catalog/main.tf, because
-- deleting an automated crawler and replacing it with hand-run DDL would have
-- been a regression in automation. Gold's tables still use the older
-- sql/athena_projections_*.sql pattern; harmonising them is in the backlog.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The three tables exist and are projected, not partition-listed.
--
-- Expected: three rows. `projection.enabled = true` in each table's parameters.
-- If a table is missing, terraform apply did not run or hit the
-- AlreadyExistsException described in modules/catalog/main.tf.
-- -----------------------------------------------------------------------------
SHOW TABLES IN crypto_silver_db;

SHOW TBLPROPERTIES crypto_silver_db.silver_binance_klines;


-- -----------------------------------------------------------------------------
-- 2. Projection actually resolves to objects.
--
-- THE FAILURE MODE THIS CATCHES IS SILENCE. A wrong storage.location.template
-- or a `dt` outside projection.dt.range does not error -- it returns zero rows,
-- which is indistinguishable from "the pipeline has not run yet". So run this
-- on a day you KNOW the Silver job wrote, and treat 0 as a failure, not as an
-- empty day.
--
-- Expected: one row per hour the stream was up, counts in the millions for
-- trades and ~45 x 60 for klines.
-- -----------------------------------------------------------------------------
SELECT hour, count(*) AS rows_in_hour, count(DISTINCT symbol) AS symbols
FROM crypto_silver_db.silver_binance_klines
WHERE dt = DATE '2026-09-05'   -- <- set to a day the job has written
GROUP BY hour
ORDER BY hour;

SELECT hour, count(*) AS rows_in_hour, count(DISTINCT symbol) AS symbols
FROM crypto_silver_db.silver_binance_trades
WHERE dt = DATE '2026-09-05'
GROUP BY hour
ORDER BY hour;


-- -----------------------------------------------------------------------------
-- 3. The partition columns mean EVENT time, not arrival time.
--
-- This is the query that proves the whole Phase 6 partitioning decision landed
-- correctly. Bronze is partitioned by Firehose's ARRIVAL time; Silver must be
-- partitioned by the event time inside the payload. If the Silver job ever
-- regressed to copying the Bronze path through, rows would leak across the
-- boundary and this returns a non-zero count.
--
-- Expected: 0.
-- -----------------------------------------------------------------------------
SELECT count(*) AS rows_in_the_wrong_partition
FROM crypto_silver_db.silver_binance_klines
WHERE dt = DATE '2026-09-05'
  AND (CAST(event_time_utc AS DATE) <> dt
       OR CAST(date_format(event_time_utc, '%H') AS INTEGER) <> hour);


-- -----------------------------------------------------------------------------
-- 4. Deduplication held.
--
-- klines are re-sent every ~2 seconds while the bar is open, so the SAME
-- (symbol, open time) legitimately arrives ~30 times on the wire. Exactly one
-- may survive into Silver.
--
-- Expected: 0 rows.
-- -----------------------------------------------------------------------------
SELECT symbol, event_time_utc, count(*) AS copies
FROM crypto_silver_db.silver_binance_klines
WHERE dt = DATE '2026-09-05'
GROUP BY symbol, event_time_utc
HAVING count(*) > 1
LIMIT 20;

SELECT symbol, agg_trade_id, count(*) AS copies
FROM crypto_silver_db.silver_binance_trades
WHERE dt = DATE '2026-09-05'
GROUP BY symbol, agg_trade_id
HAVING count(*) > 1
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 5. The event timestamp really did travel inside the payload.
--
-- producer_lag_ms is _ingested_at (stamped by the producer as the frame left
-- the WebSocket) minus Binance's own event time. It exists only because Phase 6
-- refused to let the S3 path be the only record of when something happened.
--
-- Expected: all counts non-null, p50 in the low hundreds of milliseconds. A
-- p99 in the tens of seconds means the producer is behind, not that the data
-- is wrong -- but it is the number to watch after the wake-up.
-- -----------------------------------------------------------------------------
SELECT
  count(*)                                                    AS rows_checked,
  count(producer_lag_ms)                                      AS rows_with_lag,
  approx_percentile(producer_lag_ms, 0.50)                    AS p50_lag_ms,
  approx_percentile(producer_lag_ms, 0.99)                    AS p99_lag_ms,
  min(event_time_utc)                                         AS first_event,
  max(event_time_utc)                                         AS last_event
FROM crypto_silver_db.silver_binance_trades
WHERE dt = DATE '2026-09-05';


-- -----------------------------------------------------------------------------
-- 6. CoinMarketCap Silver still answers what it answered under the crawler.
--
-- The crawler-built table and this projected one describe the SAME S3 layout
-- with the same columns, so any difference is a defect in the projection, not
-- a change in the data. Note the integer partition columns: the crawler
-- exposed y/m/d/h as strings, so a query that used to say y = '2026' now says
-- y = 2026. That is the one intended behavioural difference in this migration.
--
-- Expected: one row per hour polled, 50 distinct assets in each.
-- -----------------------------------------------------------------------------
SELECT y, m, d, h, count(*) AS rows_in_hour, count(DISTINCT asset_id) AS assets
FROM crypto_silver_db.silver_cmc
WHERE y = 2026 AND m = 9 AND d = 5
GROUP BY y, m, d, h
ORDER BY h;


-- -----------------------------------------------------------------------------
-- 7. Cost sanity: projection must PRUNE, not scan everything.
--
-- Run 6 above, then read "Data scanned" in the Athena console or via
-- GetQueryExecution. A filtered query must scan roughly one hour of Parquet,
-- not the whole table. If it scans everything, the projection is being ignored
-- -- usually because storage.location.template does not match where Spark
-- actually wrote.
-- -----------------------------------------------------------------------------
-- (no SQL; read the query statistics)
