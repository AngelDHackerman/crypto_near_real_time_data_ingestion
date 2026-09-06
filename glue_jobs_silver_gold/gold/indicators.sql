-- ============================================================================
-- indicators.sql -- the feature maths, owned in one place.  roadmap.md Phase 7
--
-- WHY THE MATHS IS SQL AND NOT PYSPARK DATAFRAME CALLS
--     This project's standing rule is one owner per fact (Phase 2.1 for bucket
--     names, Phase 3 for job names, Phase 5 for the asset list). An indicator
--     definition is a fact. Written as a chain of `.withColumn()` calls it can
--     only ever run inside a Spark cluster, which in practice means it can only
--     be verified by running a Glue job and looking at the output -- and "looks
--     plausible" is how an off-by-one in a window survives to production.
--
--     Written as SQL over a named relation, the SAME TEXT runs in Spark on
--     Glue and in DuckDB on a laptop with no JVM. tests/test_indicators.py runs
--     it against a hand-checked series and against an independent Python
--     implementation of each definition. So the thing that ships is the thing
--     that was tested, rather than its cousin.
--
--     The cost is real and worth naming: two SQL engines are not one dialect.
--     The template below stays inside the intersection deliberately -- ANSI
--     interval literals, no named WINDOW clause (the frames are expanded by the
--     caller), no engine-specific functions. Every construct in here was
--     executed in DuckDB 1.5.5 before being committed.
--
-- WHY NOTHING HERE IS RECURSIVE, AND WHAT THAT COSTS
--     Wilder's RSI, EMA and MACD are all defined recursively: today's value is
--     a function of yesterday's OUTPUT. SQL windows cannot express that, and
--     neither can Spark without either a UDF that processes a partition
--     row-by-row in Python -- destroying vectorisation over 133 million rows --
--     or an unbounded window with a decay expansion that is slower and only
--     approximately right.
--
--     So every indicator here is a plain windowed aggregate, and the RSI is
--     CUTLER'S RSI: the same formula with simple moving averages of gains and
--     losses instead of Wilder's smoothed ones. It is a published variant, not
--     an approximation of Wilder's -- it has its own defined values, which is
--     why the test checks it against its own definition rather than against
--     Wilder's tables. The practical difference is that Cutler's responds
--     slightly faster and does not carry state from before the window.
--
--     If a Wilder RSI is ever genuinely needed, the honest way is a separate
--     job that accepts the row-by-row cost, not a smoothing trick smuggled in
--     here.
--
-- WHY THE FRAMES ARE RANGE-ON-TIME AND NOT ROWS
--     Binance's own archive is gappy -- BTCUSDT-1m-2018-01 holds 44,515 rows
--     against January's 44,640 minutes -- and `ROWS BETWEEN 59 PRECEDING`
--     counts ROWS, so across a maintenance halt a "60-minute" average silently
--     becomes a 90-minute one and nothing reports it. `RANGE BETWEEN INTERVAL
--     '59' MINUTE PRECEDING` counts TIME, so a gap makes the window hold fewer
--     bars, which is the truth. `bars_in_60m` carries that count so the
--     thinning is visible to the model rather than hidden from it.
--
--     This is the same DoD line as "missing minutes treated as missing, never
--     forward-filled", enforced at the window rather than at the row.
--
-- WINDOW NAMING. `_15m` means "this bar plus the 14 minutes before it" -- a
-- 15-bar window on a dense grid, fewer across a gap. The number is the window's
-- span in minutes, always.
--
-- Placeholders %INPUT%, %W_ROW%, %W_RSI%, %W_15%, %W_60%, %W_240%, %W_1440%
-- and %EPOCH% are expanded by the caller. See gold_market_features_job.py.
--
-- %EPOCH% IS THE ONE PLACE THE TWO DIALECTS GENUINELY DIVERGE, and it is a
-- token rather than a silent difference so it stays countable: Spark spells
-- "seconds since the epoch" as unix_timestamp(), DuckDB as epoch(). Everything
-- else in this file is the same text in both engines. If that list ever grows
-- past a couple of entries, the shared-SQL idea has stopped paying for itself
-- and this should become two files that a test compares.
-- ============================================================================

WITH lagged AS (
    SELECT
        symbol,
        event_time_utc,
        source,
        open,
        high,
        low,
        close,
        volume,
        quote_volume,
        taker_buy_base_volume,
        taker_buy_quote_volume,
        trade_count,
        LAG(close)          OVER %W_ROW% AS prev_close,
        LAG(event_time_utc) OVER %W_ROW% AS prev_time
    FROM %INPUT%
),

-- Everything that needs the previous bar, plus the gap accounting that decides
-- which of those values are meaningful.
stepped AS (
    SELECT
        *,
        -- The distance to the previous bar, in minutes. 1 on a healthy grid.
        -- It is a COLUMN and not a filter: a bar after a halt is real data, and
        -- what is not real is a one-minute return computed across it.
        CASE
            WHEN prev_time IS NULL THEN NULL
            ELSE CAST(ROUND((CAST(%EPOCH%(event_time_utc) AS DOUBLE) - CAST(%EPOCH%(prev_time) AS DOUBLE)) / 60.0) AS BIGINT)
        END AS minutes_since_prev,

        CASE
            WHEN high - low IS NULL THEN NULL
            WHEN prev_close IS NULL THEN high - low
            ELSE GREATEST(high - low, ABS(high - prev_close), ABS(low - prev_close))
        END AS true_range
    FROM lagged
),

diffed AS (
    SELECT
        *,
        -- NULL, not zero, when the previous bar is not the previous MINUTE.
        -- Zero would enter the RSI's average as "no movement happened", which
        -- is a claim about a minute nobody observed.
        CASE WHEN minutes_since_prev = 1 AND prev_close IS NOT NULL
             THEN close - prev_close END AS diff_1m,
        CASE WHEN minutes_since_prev = 1 AND prev_close IS NOT NULL AND prev_close > 0
             THEN LN(close / prev_close) END AS ret_1m,
        CASE WHEN prev_close IS NOT NULL AND prev_close > 0
             THEN LN(close / prev_close) END AS ret_since_prev
    FROM stepped
),

gains AS (
    SELECT
        *,
        CASE WHEN diff_1m IS NULL THEN NULL WHEN diff_1m > 0 THEN diff_1m      ELSE 0 END AS gain_1m,
        CASE WHEN diff_1m IS NULL THEN NULL WHEN diff_1m < 0 THEN -1 * diff_1m ELSE 0 END AS loss_1m
    FROM diffed
),

windowed AS (
    SELECT
        symbol, event_time_utc, source,
        open, high, low, close,
        volume, quote_volume, taker_buy_base_volume, taker_buy_quote_volume, trade_count,
        minutes_since_prev, true_range, ret_1m, ret_since_prev,

        -- --- trend: simple moving averages of close ------------------------
        AVG(close) OVER %W_15%   AS sma_15m,
        AVG(close) OVER %W_60%   AS sma_60m,
        AVG(close) OVER %W_240%  AS sma_240m,

        -- --- momentum: return from the oldest bar still inside the window ---
        -- On a dense grid this is exactly the N-minute return. Across a gap it
        -- is the return over whatever history the window actually contains,
        -- which is the honest answer; bars_in_60m below says how much that was.
        FIRST_VALUE(close) OVER %W_15%   AS close_open_15m,
        FIRST_VALUE(close) OVER %W_60%   AS close_open_60m,
        FIRST_VALUE(close) OVER %W_240%  AS close_open_240m,
        FIRST_VALUE(close) OVER %W_1440% AS close_open_1440m,

        -- --- dispersion ----------------------------------------------------
        STDDEV_SAMP(ret_1m) OVER %W_15%  AS vol_15m,
        STDDEV_SAMP(ret_1m) OVER %W_60%  AS vol_60m,
        STDDEV_SAMP(ret_1m) OVER %W_240% AS vol_240m,
        STDDEV_SAMP(close)  OVER %W_60%  AS close_sd_60m,

        -- --- Cutler's RSI over 14 one-minute changes ------------------------
        AVG(gain_1m) OVER %W_RSI% AS avg_gain_14,
        AVG(loss_1m) OVER %W_RSI% AS avg_loss_14,

        -- --- range / volatility of the bar itself ---------------------------
        AVG(true_range) OVER %W_15% AS atr_15m,

        -- --- volume and order flow ------------------------------------------
        AVG(volume)      OVER %W_1440% AS volume_mean_1440m,
        STDDEV_SAMP(volume) OVER %W_1440% AS volume_sd_1440m,
        AVG(trade_count) OVER %W_1440% AS trade_count_mean_1440m,
        STDDEV_SAMP(trade_count) OVER %W_1440% AS trade_count_sd_1440m,
        SUM(taker_buy_base_volume) OVER %W_60% AS taker_buy_base_60m,
        SUM(volume)                OVER %W_60% AS volume_60m,

        -- --- data quality, as a feature rather than a footnote ---------------
        COUNT(close) OVER %W_60%   AS bars_in_60m,
        COUNT(close) OVER %W_1440% AS bars_in_1440m
    FROM gains
)

SELECT
    symbol,
    event_time_utc,
    source,
    open, high, low, close,
    volume, quote_volume, taker_buy_base_volume, taker_buy_quote_volume, trade_count,
    minutes_since_prev,
    ret_1m,
    ret_since_prev,

    CASE WHEN close_open_15m   > 0 THEN LN(close / close_open_15m)   END AS ret_15m,
    CASE WHEN close_open_60m   > 0 THEN LN(close / close_open_60m)   END AS ret_60m,
    CASE WHEN close_open_240m  > 0 THEN LN(close / close_open_240m)  END AS ret_240m,
    CASE WHEN close_open_1440m > 0 THEN LN(close / close_open_1440m) END AS ret_1440m,

    sma_15m,
    sma_60m,
    sma_240m,
    CASE WHEN sma_60m  > 0 THEN close   / sma_60m  END AS close_over_sma_60m,
    CASE WHEN sma_240m > 0 THEN sma_15m / sma_240m END AS sma_15m_over_240m,

    vol_15m,
    vol_60m,
    vol_240m,

    -- Bollinger position in standard deviations. NULL rather than 0 when the
    -- window is flat: a stablecoin pinned at 1.0000 has an undefined position
    -- inside a band of zero width, and 0 would read as "at the mean" -- exactly
    -- the false signal the stablecoins in the tracked universe are there to
    -- catch (data_sources.md section 5).
    CASE WHEN close_sd_60m > 0 THEN (close - sma_60m) / close_sd_60m END AS bb_z_60m,

    -- Cutler's RSI. NULL when the window has no movement at all, for the same
    -- reason: the conventional 50 is a fabricated midpoint, not an observation.
    CASE
        WHEN avg_gain_14 IS NULL OR avg_loss_14 IS NULL THEN NULL
        WHEN avg_gain_14 + avg_loss_14 = 0 THEN NULL
        ELSE 100.0 * avg_gain_14 / (avg_gain_14 + avg_loss_14)
    END AS rsi_14,

    true_range,
    atr_15m,
    CASE WHEN close > 0 THEN (high - low) / close END AS hl_range_pct,

    CASE WHEN volume_sd_1440m > 0
         THEN (volume - volume_mean_1440m) / volume_sd_1440m END AS volume_z_1440m,
    CASE WHEN trade_count_sd_1440m > 0
         THEN (trade_count - trade_count_mean_1440m) / trade_count_sd_1440m END AS trade_count_z_1440m,

    -- Aggressive-buy share of the bar's volume. This is genuine order flow and
    -- it exists back to 2017, which is the point data_sources.md section 11
    -- makes about the archive being richer than plain OHLCV.
    CASE WHEN volume     > 0 THEN taker_buy_base_volume / volume END AS taker_buy_ratio,
    CASE WHEN volume_60m > 0 THEN taker_buy_base_60m    / volume_60m END AS taker_buy_ratio_60m,
    CASE WHEN trade_count > 0 THEN quote_volume / trade_count END AS quote_per_trade,

    bars_in_60m,
    bars_in_1440m
FROM windowed
