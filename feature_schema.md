# Feature schema — `gold_market_features_1m` and `gold_ml_training`

**Version `v1`** · frozen 2026-09-06 · roadmap.md Phase 7

This is the contract between Phase 7 and Phase 8. Phase 8's DoD records a
*baseline metric*, and a baseline measured against a feature definition that
later changed is not a baseline — so the version below travels on every row as
`feature_block_version`, and changing anything in
[`glue_jobs_silver_gold/gold/indicators.sql`](./glue_jobs_silver_gold/gold/indicators.sql)
means changing it in the same commit.

---

## The three blocks, and why the schema is layered rather than flat

`data_sources.md` §11 is blunt about the constraint: the free Binance archive
gives **1-minute OHLCV back to 2017** and **nothing sub-minute before Phase 5**.
A single flat schema over both would be ~90% null in its most interesting
columns for ~99% of its rows, and a model trained on it learns "the tick
features are missing" as a proxy for "this row is old" — which is a real,
learnable, and completely useless signal.

| Block | Spans | Source | Flag on each row |
|---|---|---|---|
| **core** | 2017-07 → now | 1-minute klines (archive + stream) | always present |
| **context** | CMC ingestion → now | CoinMarketCap, as-of joined | `has_context_features` |
| **tick** | Phase 5 wake-up → now | `silver/binance/trades` | `has_tick_features` |

**The tick block is declared and not computed.** `silver/binance/trades` exists
and has no rows until the wake-up. A column that is null for every row in the
lake is a promise, not a feature, so `has_tick_features` is written `false` and
the columns do not exist yet. The day it becomes true is then visible *in the
data* rather than in a commit message.

---

## Grain and identity

One row per **(Binance trading pair, UTC minute)** — partitioned `dt` / `symbol`.

The grain is a *pair*, not a CoinMarketCap *asset*: `BTCUSDT` is the thing that
has a 1-minute bar. `cmc_id` is attached by the join and is a column, never the
partition — partitioning on it would name the row after the source it is
enriched *by* instead of the one it comes *from*.

The five `has_stream = false` assets (USDT, DAI, XMR, HYPE, KAS) do not appear
here at all, by construction. They flow into the hourly Gold datasets only.

---

## Core block

Computed by `indicators.sql`, verified by
[`tests/test_indicators.py`](./tests/test_indicators.py) on DuckDB against an
independent implementation and against hand-computed values.

| Column | Type | Definition |
|---|---|---|
| `event_time_utc` | timestamp | Bar **open** time. The bar's identity, and what the archive keys on |
| `source` | string | `backfill` or `stream` |
| `open` `high` `low` `close` | double | As published |
| `volume` `quote_volume` | double | Base and quote volume |
| `taker_buy_base_volume` `taker_buy_quote_volume` | double | Aggressive-buy volume |
| `trade_count` | bigint | Trades in the bar |
| `minutes_since_prev` | bigint | Distance to the previous bar. **1 on a healthy grid** |
| `ret_1m` | double | `ln(close/prev_close)`, **null unless `minutes_since_prev = 1`** |
| `ret_since_prev` | double | The same log return over whatever gap actually occurred |
| `ret_15m` `ret_60m` `ret_240m` `ret_1440m` | double | Return from the oldest bar still inside the window |
| `sma_15m` `sma_60m` `sma_240m` | double | Simple moving averages of `close` |
| `close_over_sma_60m`, `sma_15m_over_240m` | double | Trend ratios |
| `vol_15m` `vol_60m` `vol_240m` | double | Sample stdev of `ret_1m` |
| `bb_z_60m` | double | `(close − sma_60m) / stdev(close)`. **Null when the band has zero width** |
| `rsi_14` | double | **Cutler's RSI** over 14 one-minute changes. **Null on a perfectly flat window** |
| `true_range`, `atr_15m` | double | Wilder's true range, and its 15-minute mean |
| `hl_range_pct` | double | `(high − low) / close` |
| `volume_z_1440m`, `trade_count_z_1440m` | double | z-score against the trailing day |
| `taker_buy_ratio` | double | `taker_buy_base_volume / volume` — order flow, available since 2017 |
| `taker_buy_ratio_60m` | double | The same, aggregated over the hour |
| `quote_per_trade` | double | `quote_volume / trade_count` — mean trade size |
| `bars_in_60m`, `bars_in_1440m` | bigint | **How much data the window actually held** |

### Four decisions worth defending

**1. Every window is `RANGE`-on-time, never `ROWS`.** Binance's own archive is
gappy — `BTCUSDT-1m-2018-01` holds **44,515 rows against January's 44,640
minutes**, confirmed by the backfill rehearsal on 2026-09-06. `ROWS BETWEEN 59
PRECEDING` counts *rows*, so across a halt a "60-minute" average silently
becomes a 90-minute one. Counting *time* makes a gap shrink the window instead,
and `bars_in_60m` reports the shrinkage rather than hiding it.

**2. Nothing is recursive, and `rsi_14` is Cutler's, not Wilder's.** Wilder's
RSI, EMA and MACD are defined so that today's value depends on yesterday's
*output*. SQL windows cannot express that, and Spark can only fake it with a
row-by-row Python UDF over 133 million rows. Cutler's RSI is a published variant
using simple moving averages of gains and losses — **not an approximation of
Wilder's**, a different indicator with its own defined values, which is why the
tests check it against its own definition.

**3. A flat series returns `null`, not the conventional midpoint.** A stablecoin
pinned at 1.0000 has no relative strength and no position inside a zero-width
band. RSI 50 and `bb_z` 0 would be *fabricated observations* — and the tracked
universe carries stablecoins precisely as a negative control (`data_sources.md`
§5): a model that emits signals on them is broken, and it should not be handed
the inputs that let it.

**4. Missing minutes stay missing.** Nothing is forward-filled anywhere. A
one-minute return across a thirty-minute halt does not exist, so `ret_1m` is
null there and `ret_since_prev` carries the return that *does* exist.

---

## Context block

Attached by an **as-of, backward join on `cmc_id`** — never on the ticker symbol,
which case-shifts, gets renamed and gets re-issued (`data_sources.md` §6).

| Column | Type | Notes |
|---|---|---|
| `cmc_id`, `asset_symbol` | int, string | From `config/tracked_assets.json` |
| `price_cmc` | double | **Never merged with `close`.** A cross-exchange aggregate is not one venue's execution |
| `market_cap`, `market_cap_dominance`, `circulating_supply` | double | Hourly, forward-carried |
| `cmc_snapshot_age_seconds` | bigint | How old the attached snapshot is |
| `cmc_stale` | boolean | `age > 3h`, i.e. three missed hourly runs |
| `price_divergence_bps` | double | `(close − price_cmc)/price_cmc × 10⁴`, **computed only when not stale** |

**Backward, never forward.** Attaching a snapshot from the future is look-ahead
leakage, and its signature is a backtest that looks excellent and a live model
that does not. A snapshot stamped at exactly the bar's minute *is* included —
it was observable then.

**Staleness is a column, not a silence.** A CoinMarketCap outage must not present
itself as a frozen market cap that looks like live data.

---

## Label block — `gold_ml_training` only

| Column | Type | Definition |
|---|---|---|
| `y_up` | int | `1` if the forward log return over `label_horizon_min` exceeds `label_threshold_bps` |
| `y_fwd_ret` | double | That forward log return |
| `label_span_minutes` | double | How far the forward window actually reached |
| `label_horizon_min` | int | `60` |
| `label_threshold_bps` | double | `20` |
| `sample_stride_min` | int | `60` |
| `label_version` | string | `h60m_t20bps` |

**The threshold is not a tuning knob.** Binance's taker fee is 10 bps a side, so
a round trip costs ~20 bps before slippage. "The price went up" marks a great
many moves that would have **lost money**; "moved enough to cover its own costs"
is the smallest change that makes the target mean something. It also makes the
positive class a minority — which is why Phase 8's baseline metric is **PR-AUC**
and not accuracy. On a class this imbalanced, "always predict no" scores well and
does nothing.

**Rows are sampled at the horizon's own stride, and that is a statistical
requirement rather than a size optimisation.** At a 60-minute horizon the labels
of two adjacent minutes share 59 minutes of outcome; they are not independent
observations, and scoring them as such inflates every validation number. Sampling
on a fixed epoch-anchored grid makes consecutive retained rows have **disjoint
label windows** — and anchoring to the epoch rather than to each asset's first
bar keeps a cross-sectional row genuinely cross-sectional.

**The last rows of the table are unlabelable, and say so.** The forward window
would otherwise return the row's own close — a forward return of exactly zero,
labelling as a confident negative. `label_span_minutes` must reach 80% of the
horizon or `y_up` is null.

---

## Changing this schema

1. Edit `indicators.sql`.
2. Update `tests/test_indicators.py` — it will fail first, which is the point.
3. Bump `feature_block_version` in `terraform/envs/crypto/variables.tf`.
4. Update this file.
5. Add the column to `terraform/modules/catalog/gold_tables.tf`. **A column
   absent from the catalog is invisible to Athena, not an error.**

Step 5 is the one that bites. Partition projection and hand-maintained column
lists both fail by *returning nothing*, and Phase 7 found exactly that already
in the DDL it replaced: `gold_ohlc` still projected the pre-Phase-4 list of
**eleven** asset ids, so 40 of the 50 tracked assets would have been silently
invisible.
