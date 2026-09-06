-- ============================================================================
-- Phase 7 verification -- runs at the wake-up, not now.  roadmap.md Phase 7
--
-- Three of Phase 7's DoD lines cannot be closed while the project is dormant,
-- and this file is how they stop being wishes. Same device Phase 6 used in
-- sql/athena_verification_silver_phase6.sql: the check is WRITTEN DOWN before
-- it can be run, so "we will verify the overlap" is a query someone executes
-- rather than a sentence someone remembers.
--
-- What each section proves, and which DoD line it closes:
--
--   1  the backfill landed and reaches 2017          -- "archive backfilled"
--   2  aliases were stitched                          -- "aliases stitched"
--   3  backfill and stream agree on the overlap       -- "compared field by field"
--   4  gaps are gaps, not forward-fills               -- "missing minutes missing"
--   5  no null explosion at series boundaries         -- "no null explosion"
--   6  the feature table is queryable and sane        -- "features queryable"
--
-- Section 3 is the one that cannot be faked: it is only possible BECAUSE the
-- archive and the stream carry the same twelve fields from the same exchange.
-- If those rows disagree, the producer is wrong, and nothing else in this
-- project would have told us.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The backfill exists, and reaches where it claims to
-- ---------------------------------------------------------------------------
-- Expect: ~45 symbols, min(dt) in 2017-07 for BTC/ETH, ~133M rows overall.
-- A min(dt) of 2026 means the projection range was not widened and Athena is
-- hiding the rows rather than reporting them -- the failure mode that made
-- backfill_projection_start_date a variable.
SELECT
    symbol,
    min(dt)      AS first_day,
    max(dt)      AS last_day,
    count(*)     AS bars,
    count(DISTINCT dt) AS days_present
FROM crypto_silver_db.silver_binance_klines
WHERE source = 'backfill'
GROUP BY symbol
ORDER BY first_day;

-- ---------------------------------------------------------------------------
-- 2. The renames were stitched, so months did not vanish silently
-- ---------------------------------------------------------------------------
-- RENDER must show history before 2024-07 (it came from RNDRUSDT) and POL
-- before 2024-09 (from MATICUSDT). If either starts at its rename date, the
-- alias walk did not run and the file looks clean while missing more history
-- than it contains: 33 months for RENDER, 66 for POL.
SELECT
    symbol,
    min(dt) AS first_day,
    count(*) AS bars
FROM crypto_silver_db.silver_binance_klines
WHERE source = 'backfill'
  AND symbol IN ('RENDERUSDT', 'POLUSDT')
GROUP BY symbol;

-- ---------------------------------------------------------------------------
-- 3. THE OVERLAP: backfill vs stream, field by field
-- ---------------------------------------------------------------------------
-- Re-download a month the stream already covered (the backfill job's FORCE
-- argument exists for this), then run this. Every count below should be 0.
--
-- A non-zero close_mismatch means the producer, the Silver job or the dedup
-- is wrong -- these are the same bars computed by the same exchange, so there
-- is no legitimate reason for them to differ.
--
-- Tolerances are relative and tiny: the two paths reach Parquet through
-- different casts (archive CSV string -> double; wire JSON string -> double),
-- so exact equality would flag representation noise as a defect.
WITH b AS (
    SELECT symbol, event_time_utc, open, high, low, close, volume, trade_count
    FROM crypto_silver_db.silver_binance_klines
    WHERE source = 'backfill' AND dt BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
),
s AS (
    SELECT symbol, event_time_utc, open, high, low, close, volume, trade_count
    FROM crypto_silver_db.silver_binance_klines
    WHERE source = 'stream' AND dt BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
)
SELECT
    count(*)                                                             AS overlapping_bars,
    count_if(abs(b.close  - s.close)  > 1e-8 * greatest(abs(b.close), 1))  AS close_mismatch,
    count_if(abs(b.open   - s.open)   > 1e-8 * greatest(abs(b.open), 1))   AS open_mismatch,
    count_if(abs(b.high   - s.high)   > 1e-8 * greatest(abs(b.high), 1))   AS high_mismatch,
    count_if(abs(b.low    - s.low)    > 1e-8 * greatest(abs(b.low), 1))    AS low_mismatch,
    count_if(abs(b.volume - s.volume) > 1e-6 * greatest(abs(b.volume), 1)) AS volume_mismatch,
    count_if(b.trade_count <> s.trade_count)                             AS trade_count_mismatch
FROM b
JOIN s ON b.symbol = s.symbol AND b.event_time_utc = s.event_time_utc;

-- And the other half of the same question: bars one side has and the other
-- does not. A stream-only bar in the overlap is normal at the edges of the
-- window; a large count is a delivery gap worth explaining.
SELECT
    count_if(s.event_time_utc IS NULL) AS backfill_only,
    count_if(b.event_time_utc IS NULL) AS stream_only
FROM      (SELECT symbol, event_time_utc FROM crypto_silver_db.silver_binance_klines
           WHERE source = 'backfill' AND dt BETWEEN DATE '2026-09-01' AND DATE '2026-09-30') b
FULL JOIN (SELECT symbol, event_time_utc FROM crypto_silver_db.silver_binance_klines
           WHERE source = 'stream'   AND dt BETWEEN DATE '2026-09-01' AND DATE '2026-09-30') s
       ON b.symbol = s.symbol AND b.event_time_utc = s.event_time_utc;

-- ---------------------------------------------------------------------------
-- 4. Gaps are gaps
-- ---------------------------------------------------------------------------
-- January 2018 must show ~44,515 bars for BTCUSDT, NOT 44,640. A dense count is
-- the alarming result here: it would mean something filled the halts in.
SELECT
    count(*) AS bars_2018_01,
    44640 - count(*) AS missing_minutes
FROM crypto_silver_db.silver_binance_klines
WHERE symbol = 'BTCUSDT' AND dt BETWEEN DATE '2018-01-01' AND DATE '2018-01-31';

-- The gap distribution as the feature table sees it. minutes_since_prev = 1 is
-- the healthy grid; anything else is a halt, and it should be rare and
-- attributable rather than absent.
SELECT
    minutes_since_prev,
    count(*) AS rows
FROM crypto_gold_db.gold_market_features_1m
WHERE dt BETWEEN DATE '2018-01-01' AND DATE '2018-01-31'
GROUP BY minutes_since_prev
ORDER BY rows DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 5. No null explosion at series boundaries
-- ---------------------------------------------------------------------------
-- The warm-up window exists so indicators do not restart from nothing at every
-- midnight. If it is broken, the null rate for rsi_14 spikes in the first
-- minutes of each day and is near zero for the rest -- a daily sawtooth that is
-- an artefact of the job's own scheduling, not of the market.
--
-- Expect: hour 0 materially the same as every other hour.
SELECT
    hour(event_time_utc) AS hour_utc,
    count(*)             AS rows,
    round(100.0 * count_if(rsi_14      IS NULL) / count(*), 3) AS pct_null_rsi,
    round(100.0 * count_if(ret_60m     IS NULL) / count(*), 3) AS pct_null_ret_60m,
    round(100.0 * count_if(vol_60m     IS NULL) / count(*), 3) AS pct_null_vol_60m
FROM crypto_gold_db.gold_market_features_1m
WHERE dt BETWEEN DATE '2024-06-01' AND DATE '2024-06-30'
GROUP BY hour(event_time_utc)
ORDER BY hour_utc;

-- ---------------------------------------------------------------------------
-- 6. The features are queryable and the maths is in range
-- ---------------------------------------------------------------------------
-- rsi_14 outside [0,100] is impossible by construction, so a non-zero count
-- here means the deployed SQL is not the SQL the tests verified.
SELECT
    count(*)                                        AS rows,
    count_if(rsi_14 < 0 OR rsi_14 > 100)            AS rsi_out_of_range,
    count_if(taker_buy_ratio < 0 OR taker_buy_ratio > 1) AS taker_ratio_out_of_range,
    count_if(high < low)                            AS impossible_bars,
    count_if(bars_in_60m > 60)                      AS window_over_full,
    approx_percentile(rsi_14, 0.5)                  AS median_rsi
FROM crypto_gold_db.gold_market_features_1m
WHERE dt BETWEEN DATE '2024-06-01' AND DATE '2024-06-30';

-- The stablecoin negative control, stated as a query. USDCUSDT sits at 1.0000,
-- so a non-null RSI here means the flat-series guard is gone and the model is
-- being handed fabricated observations.
SELECT
    symbol,
    count(*)                       AS rows,
    count_if(rsi_14 IS NOT NULL)   AS rsi_not_null,
    count_if(bb_z_60m IS NOT NULL) AS bb_not_null
FROM crypto_gold_db.gold_market_features_1m
WHERE symbol IN ('USDCUSDT', 'FDUSDUSDT')
  AND dt BETWEEN DATE '2024-06-01' AND DATE '2024-06-30'
GROUP BY symbol;

-- Class balance of the training label. If the positive rate is near 50% the
-- threshold is not being applied; if it is near 0% the horizon is too short for
-- the threshold and Phase 8 has nothing to learn from.
SELECT
    label_version,
    count(*)                                   AS rows,
    round(100.0 * count_if(y_up = 1) / count(*), 2) AS pct_positive
FROM crypto_gold_db.gold_ml_training
GROUP BY label_version;
