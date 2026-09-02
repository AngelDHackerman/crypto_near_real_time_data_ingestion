# Data source strategy — Phase 4

**Status: decided.** This file is the decision record for what feeds the pipeline.
No infrastructure was created or woken up to write it; Phase 5 is what builds
against these decisions.

Everything numeric below was **read from a live source on 2026-08-26**, not
recalled — the Binance symbol universe from `api.binance.com/api/v3/exchangeInfo`,
the trade volumes from `/api/v3/ticker/24hr`, and the CoinMarketCap ids from
CoinMarketCap's own public listing endpoint (which costs zero API credits, so the
project's free-tier quota was never touched). The one-line reproduction recipe for
each is at the bottom.

---

## 1. The decision in one paragraph

The pipeline takes **two sources with different jobs**. Binance's public WebSocket
streams carry price and volume at tick granularity and become the primary capture
mechanism, replacing batch polling. CoinMarketCap is **not** replaced: it drops
from every 5 minutes to hourly and changes role, from "the feed" to "the market
context the exchange cannot know" — cross-exchange aggregate price, market cap,
circulating and total supply, dominance and rank. The two are kept in separate
Bronze and Silver tables and joined in Gold, as-of, on the **CoinMarketCap id**.

---

## 2. Why the old source could not stay

The Lambda polled CoinMarketCap `quotes/latest` every 5 minutes: 8,640 calls a
month against a 10,000-credit free tier, ~86% of quota. The 5-minute cadence was
therefore never a design choice — it was the ceiling of the free tier, which is a
bad reason for a grain.

The deeper problem is architectural. `quotes/latest` is REST polling. Putting
Kinesis in front of a poller does not make the pipeline streaming; it makes it a
poller with a queue attached, and that collapses under the first follow-up
question in an interview. The project is called *near real-time data ingestion*
and the ingestion has to actually be event-driven for the name to be honest.

---

## 3. Why both sources, and what each one uniquely gives

| | Binance WebSocket | CoinMarketCap REST |
|---|---|---|
| Mechanism | Server-pushed events, persistent connection | Request/response polling |
| Grain | Per trade (sub-second) | Hourly snapshot |
| Price | One venue's executed price | Volume-weighted across many exchanges |
| Volume | Real, per trade, on this venue | Aggregate 24 h across all venues |
| Market cap | **Not available** | Yes |
| Circulating / total / max supply | **Not available** | Yes |
| Dominance, rank | **Not available** | Yes |
| Cost | Free, no auth, no quota | Free tier, credit-metered |
| Coverage | Only assets with a live USDT pair | Every listed asset |

Four things justify keeping CoinMarketCap rather than deleting it:

1. **Features Binance structurally cannot provide.** Market cap, supply and
   dominance are properties of an *asset*, not of a *pair*. An exchange only knows
   what trades on it. Supply-derived features (float, dilution schedule, market
   cap rank momentum) are among the more predictive non-price features available,
   and they exist only in the aggregator.
2. **Cross-validation.** Binance's price is one venue's price. Comparing it hourly
   against a multi-exchange aggregate makes single-venue anomalies — a thin book,
   a fat-finger wick, a venue-specific depeg — *detectable* rather than silently
   ingested as truth. That divergence becomes a feature, not just a check.
3. **A blind-pipeline guard.** If the WebSocket drops and reconnection fails, the
   hourly Lambda keeps writing. The pipeline degrades to coarse instead of going
   dark, and the gap is visible in the data rather than being an absence.
4. **Coverage the stream does not have.** Five of the fifty tracked assets have no
   Binance USDT pair at all (§6). Without CoinMarketCap they would simply not exist
   in the dataset.

---

## 4. "Near real-time", stated honestly

This is **near real-time, not real-time**. Latency accumulates at every hop: the
exchange's own matching-to-publish delay, network transit, deserialisation in the
producer, batching and `PutRecords` into Kinesis, Firehose buffering (seconds to
minutes by configuration), and finally the consumer. End to end, an event is
visible in S3 on the order of **tens of seconds to a few minutes**, dominated by
the Firehose buffer, not by the WebSocket.

That is still a categorical improvement over a 5-minute poll — the *event* is
captured the moment it happens and carries its own exchange timestamp, so
granularity is no longer destroyed at capture time even if delivery is buffered.
The claim to defend in an interview is exactly that: **capture is real-time,
delivery is near real-time, and the payload carries the event time so the
difference is measurable rather than hidden.**

---

## 5. The asset list: fixed at 50, hand-picked

**Decided: the universe is STATIC.** A live `listings/latest` top-50 lookup would
silently change which assets are tracked every time a coin crosses the market-cap
boundary. That is drift wearing a different hat: the training set stops being
reproducible, features acquire null gaps where an asset entered or left, and a
dataset from six months ago becomes uninterpretable. The list is curated once,
committed as code in [`config/tracked_assets.json`](./config/tracked_assets.json),
and changed only by an explicit commit that says why.

**Selection criterion: diversity of behaviour, not market-cap rank.** A model
trained on the top 50 by market cap sees fifty variations of the same thing —
liquid assets that mostly track Bitcoin. What a model needs is assets that behave
*differently from each other*: different volatility regimes, different drivers,
different failure modes, and controls that should produce no signal at all.

The ten cohorts, and what each is there to teach the model:

| Cohort | n | What it contributes |
|---|---:|---|
| Market beta anchors | 8 | The common factor. Everything else is measured against these |
| Stablecoins | 4 | **Negative control.** Near-zero volatility — a model that emits signals here is broken |
| Commodity-pegged | 2 | A non-crypto risk factor inside the crypto tape (gold), near-zero correlation to BTC |
| Alternative L1s | 10 | Mid-cap beta amplification, unlock schedules, matched pairs (APT/SUI) |
| L2 / scaling | 3 | Sector beta plus a matched pair (ARB/OP) that isolates protocol news |
| PoW and legacy payments | 6 | Long histories, halving cycles, high-kurtosis privacy-coin repricings |
| DeFi | 7 | Usage- and rate-driven assets; liquidation cascades that lead the market down |
| AI / compute | 4 | Narrative-driven regimes and a structural break (a token merger) |
| Memecoins | 4 | Pure reflexivity — the control for "price is the only signal" |
| Structural single-source | 2 | Assets the stream cannot see, on purpose (§6) |

Three inclusions are worth defending specifically:

- **The stablecoins are the negative control**, and one of them (USDC) is
  *streamed*, so the control exists at the same grain as the signal. If the model
  produces a buy signal on a series pinned at 1.0000, that is a bug caught by
  design rather than by luck.
- **PAXG and XAUt are gold.** They trade on a crypto venue but track a
  non-crypto asset, so they give the feature set a genuinely orthogonal factor.
  Their spread against each other isolates issuer credit risk from the metal.
- **ALGO is in structural decline.** A universe of survivors teaches survivorship
  bias. The model needs assets with negative drift.

Of the 11 provisional ids, **10 survive**; BAT (`1697`) is dropped — it was in the
list for no recorded reason and adds no behaviour the other 49 do not cover.

### The 50, with the reason each one is in the set

#### Market beta anchors (8)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `1` | BTC | Bitcoin | `BTCUSDT` | Market beta. Every other series in the set is measured against it; without it no correlation feature has a reference. |
| `1027` | ETH | Ethereum | `ETHUSDT` | Second beta factor and the settlement layer for most tokens here, so it carries idiosyncratic gas/L2 news on top of market beta. |
| `1839` | BNB | BNB | `BNBUSDT` | Exchange-native beta. It reacts to flow on the very venue we stream from, which makes venue stress observable. |
| `52` | XRP | XRP | `XRPUSDT` | Large cap that decouples from BTC on legal and regulatory news - a regime the model must not confuse with market moves. |
| `5426` | SOL | Solana | `SOLUSDT` | High-beta large cap: the amplified version of the BTC move. Pairs with BTC to give the model a beta spread. |
| `1958` | TRX | TRON | `TRXUSDT` | Large cap with unusually low realised volatility for its size - a slow large cap against SOL's fast one. |
| `74` | DOGE | Dogecoin | `DOGEUSDT` | The liquid meme: large-cap depth with meme-grade volatility. Bridges the anchor and meme cohorts. |
| `2010` | ADA | Cardano | `ADAUSDT` | Large cap on a slow news cycle and low on-chain throughput; long stretches of near-random walk. |

#### Stablecoins — the negative control (4)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `825` | USDT | Tether USDt | `— *(CMC only)*` | Volatility floor and the numeraire itself. CMC-only by construction: USDT is Binance's quote asset, so USDTUSDT cannot exist. |
| `3408` | USDC | USDC | `USDCUSDT` | The STREAMED negative control. USDCUSDT is a real pair pinned near 1.0: if the model emits signals on this series, the model is broken. |
| `4943` | DAI | Dai | `— *(CMC only)*` | Over-collateralised peg - it breaks differently from a fiat-backed one. CMC-only: `DAIUSDT` existed for two months (2020-07 to 2020-08) and has been `BREAK` ever since. |
| `26081` | FDUSD | First Digital USD | `FDUSDUSDT` | Venue-native stablecoin. Its depegs are a direct read on Binance-specific stress rather than on the wider market. |

#### Commodity-pegged (2)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `4705` | PAXG | PAX Gold | `PAXGUSDT` | Gold, streamed. A non-crypto risk factor inside the crypto tape - near-zero correlation to BTC by design. |
| `5176` | XAUt | Tether Gold | `XAUTUSDT` | Second gold token. The PAXG/XAUt spread isolates issuer credit risk from the gold price itself. |

#### Alternative L1s (10)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `5805` | AVAX | Avalanche | `AVAXUSDT` | EVM-compatible L1 with a subnet story; trades as a mid-cap beta amplifier. |
| `6636` | DOT | Polkadot | `DOTUSDT` | Parachain L1 whose supply schedule and unlocks drive moves independent of price momentum. |
| `6535` | NEAR | NEAR Protocol | `NEARUSDT` | L1 repositioned around AI narratives - sits between the L1 and AI cohorts, which is exactly the ambiguity worth training on. |
| `21794` | APT | Aptos | `APTUSDT` | Move-VM L1 with a large scheduled-unlock overhang: a clean example of supply-driven drawdown. |
| `20947` | SUI | Sui | `SUIUSDT` | The other Move-VM L1. APT/SUI is a near-matched pair, so divergence between them is signal rather than beta. |
| `3794` | ATOM | Cosmos | `ATOMUSDT` | Interoperability hub with a long history and a mature, low-momentum tape. |
| `4030` | ALGO | Algorand | `ALGOUSDT` | Long-lived PoS L1 in structural decline - the model needs assets with negative drift, not only survivors. |
| `4642` | HBAR | Hedera | `HBARUSDT` | Enterprise/DAG L1 that moves on institutional announcements rather than on retail flow. |
| `8916` | ICP | Internet Computer | `ICPUSDT` | Post-hype L1 with an extreme boom-bust history; heavy tails the Gaussian assumptions will fail on. |
| `22861` | TIA | Celestia | `TIAUSDT` | Modular data-availability L1: a young asset with a short history, which tests how the features behave near series start. |

#### L2 / scaling (3)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `28321` | POL | Polygon (prev. MATIC) | `POLUSDT` | Ethereum scaling token that survived a ticker AND id migration (MATIC to POL) - the reason the join key is the CMC id. |
| `11841` | ARB | Arbitrum | `ARBUSDT` | Optimistic rollup governance token; moves with L2 activity and with airdrop/unlock events. |
| `11840` | OP | Optimism | `OPUSDT` | The other optimistic rollup. ARB/OP is a matched pair like APT/SUI, isolating protocol news from sector beta. |

#### PoW and legacy payments (6)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `2` | LTC | Litecoin | `LTCUSDT` | The original BTC beta clone, live since 2011, with a halving cycle of its own. Binance's archive reaches 2017-12 (`LTCBTC` reaches 2017-07) — see §11; the asset is 13 years old, the *data* is not. |
| `1831` | BCH | Bitcoin Cash | `BCHUSDT` | BTC fork that shares its hash algorithm; correlation to BTC is structural, not behavioural. |
| `512` | XLM | Stellar | `XLMUSDT` | Payments network that trades partly on XRP news - a cross-asset dependency worth learning. |
| `1321` | ETC | Ethereum Classic | `ETCUSDT` | The ETH fork left on PoW; the ETH/ETC spread separates the chain from the asset. |
| `1437` | ZEC | Zcash | `ZECUSDT` | Privacy PoW coin with violent narrative-driven repricings. High-kurtosis training material. |
| `328` | XMR | Monero | `— *(CMC only)*` | Deliberate CMC-only asset: delisted from Binance in Feb 2024. It proves the pipeline degrades to one source instead of failing. |

#### DeFi (7)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `1975` | LINK | Chainlink | `LINKUSDT` | Oracle infrastructure; revenue-like usage growth rather than pure speculation. |
| `7083` | UNI | Uniswap | `UNIUSDT` | DEX governance blue chip. Its volume is the on-chain mirror of the CEX volume we stream. |
| `7278` | AAVE | Aave | `AAVEUSDT` | Lending blue chip; liquidation cascades make it lead the market on the way down. |
| `6538` | CRV | Curve DAO Token | `CRVUSDT` | Stableswap DEX with heavy emissions - persistent negative drift from token issuance. |
| `8000` | LDO | Lido DAO | `LDOUSDT` | Liquid staking governance; a levered bet on ETH staking flows rather than on ETH price. |
| `21159` | ONDO | Ondo | `ONDOUSDT` | Real-world-asset protocol. Trades on rate and regulatory news that has no crypto-native equivalent. |
| `30171` | ENA | Ethena | `ENAUSDT` | Synthetic-dollar protocol whose token is a levered bet on funding rates - a derivatives-driven regime. |

#### AI / compute (4)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `22974` | TAO | Bittensor | `TAOUSDT` | Decentralised ML network; the flagship AI-narrative asset and a very high-priced unit (feature scaling test). |
| `5690` | RENDER | Render | `RENDERUSDT` | GPU rendering network that also survived a ticker rename (RNDR to RENDER) with its CMC id intact. |
| `3773` | FET | Artificial Superintelligence Alliance | `FETUSDT` | AI token formed by a token merger - its history contains a structural break the model must tolerate. |
| `13502` | WLD | Worldcoin | `WLDUSDT` | Identity/AI token with an aggressive unlock schedule; supply shock dominates demand. |

#### Memecoins (4)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `5994` | SHIB | Shiba Inu | `SHIBUSDT` | The original ERC-20 meme: enormous supply, sub-cent price, and a tick size that quantises returns. |
| `24478` | PEPE | Pepe | `PEPEUSDT` | Pure reflexive meme on Ethereum with no cash flow story at all - the control for 'price is the only signal'. |
| `23095` | BONK | Bonk | `BONKUSDT` | Solana meme: it moves with SOL activity, so it is a meme WITH a beta, unlike PEPE. |
| `34466` | PENGU | Pudgy Penguins | `PENGUUSDT` | NFT-collectible meme - the same volatility class driven by a different community cycle. |

#### Structural single-source (2)

| CMC id | Symbol | Name | Binance stream symbol | Why it is tracked |
|---:|---|---|---|---|
| `32196` | HYPE | Hyperliquid | `— *(CMC only)*` | Top-10 asset by market cap with NO Binance spot pair. Included precisely so the set contains a large asset the stream cannot see. |
| `20396` | KAS | Kaspa | `— *(CMC only)*` | Mineable DAG L1 with real market cap and no Binance listing. Second CMC-only asset, from a different behavioural class. |

---

## 6. The mapping: CoinMarketCap id ↔ Binance symbol

**The join key is `cmc_id`. Never the symbol string.** Three concrete traps were
found while building the mapping against live data on 2026-08-26, and any one of
them silently corrupts a symbol-keyed join:

| Trap | What happens | Found in |
|---|---|---|
| **Case** | CoinMarketCap spells it `XAUt`; Binance's base asset is `XAUT`. A case-sensitive equality join drops the asset; a case-insensitive one hides that the two systems disagree | Tether Gold |
| **Rename** | The ticker changed (`RNDR` → `RENDER`) while the CoinMarketCap id `5690` stayed constant. A symbol join breaks at the rename date; an id join does not notice. Verified today: Binance's base asset is `RENDER`, and `RNDRUSDT` no longer exists | Render |
| **Re-issue** | The asset migrated *and* got a **new id**: MATIC (`3890`) → POL (`28321`). Verified today: id `3890` still resolves, as symbol `MATIC`, with `status = untracked`. Here the id is the thing that correctly says "this is a different asset" — a symbol join would have quietly stitched two different tokens into one series | Polygon |
| **Collision** | Several distinct CoinMarketCap entries share a symbol (`SUN`, `NFT`, `M`, …). A symbol join can attach the wrong asset's market cap entirely | CoinMarketCap universe at large |

These traps are not only a join problem. They **split the historical archive too**:
Binance files the pre-rename months under the old ticker, so a backfill that asks
only for `RENDERUSDT` gets 27 months and silently misses the 33 under `RNDRUSDT`
(and 66 under `MATICUSDT` for POL). That is why each asset carries
`binance_symbol_aliases` — see §11.

So `config/tracked_assets.json` is the **bridge table**: `cmc_id` is the primary
key, `binance_symbol` is an attribute of it, `binance_symbol_aliases` holds the
same asset's earlier Binance tickers, `binance_history_from` records how far the
archive reaches, and `has_stream` is an explicit boolean rather than something
inferred from a null. It is loaded as a small
broadcast dimension by the Gold job and read by both the Lambda (for its id list)
and the producer (for its subscription list), so the two sources cannot drift
apart in what they think they are tracking.

### Assets present in only one source

Five of the fifty have **no live Binance USDT spot pair**. This is not an oversight
— it is what makes the two-source design demonstrably necessary rather than
decorative:

| CMC id | Symbol | Evidence in `exchangeInfo` | Why there is no stream |
|---:|---|---|---|
| `825` | USDT | 734 pairs where USDT is the **quote** asset; as a base it appears only against fiat (`USDTTRY`, `USDTBRL`, `USDTARS`, `USDTZAR`, `USDTUAH`) | **Structurally impossible.** USDT is Binance's quote asset, so `USDTUSDT` cannot exist. The numéraire cannot be streamed against itself |
| `4943` | DAI | 5 pairs as base — `DAIUSDT`, `DAIBTC`, `DAIBNB`, `DAIBUSD`, `DAIJPY` — **all `BREAK`** | Delisted, and it barely existed: `DAIUSDT` has **two months** of history, 2020-07 to 2020-08. Never an established market |
| `328` | XMR | 5 pairs as base — `XMRUSDT`, `XMRBTC`, `XMRETH`, `XMRBNB`, `XMRBUSD` — **all `BREAK`** | **Delisted**, and the archive dates it: `XMRUSDT` runs 2019-03 → **2024-02** and stops. In the set precisely because it proves the pipeline degrades to one source instead of failing |
| `32196` | HYPE | **zero rows**, in any role, any status | Never listed. A **top-10 asset by market cap** that Binance does not carry at all — the stream is not a superset of the market |
| `20396` | KAS | **zero rows**, in any role, any status | Never listed. A mineable DAG L1, a behaviour class otherwise unrepresented |

Binance's `exchangeInfo` distinguishes the two cases cleanly, and it is worth
naming because they fail differently. **`BREAK` means the pair existed and was
halted** — DAI and XMR were tradeable once, and their records survive as tombstones.
**No row at all means never listed** — HYPE and KAS have never had a Binance market.
A `BREAK` asset can in principle come back; an absent one requires a listing
decision. Either way the producer must never subscribe to them: a `BREAK` symbol
accepts a subscription and then delivers nothing, which is the silent-failure mode
`has_stream` exists to prevent.

USDT is the subtlest of the five. It *does* have live Binance pairs — `USDTTRY`,
`USDTBRL`, `USDTARS` and other fiat crosses are all `TRADING`. They are useless
here: they price USDT in lira, reais or pesos, so streaming one would import that
currency's FX volatility into a series that is supposed to be the volatility floor.
The asset is streamable and still correctly marked `has_stream = false`, because
what is streamable is not the measurement we need.

**There are no Binance-only assets by construction**, because every streamed symbol
is derived from an asset that already has a CoinMarketCap id. But an asset can
*become* single-source mid-life — XMR is the proof that it happens — so
`has_stream` is a config flag the jobs read, never an assumption baked into code.
A delisting becomes a one-line commit, not an incident.

**What happens to a single-source asset downstream:** it appears in the hourly
Gold datasets with its CoinMarketCap columns populated and its streaming columns
absent, flagged by `has_stream = false`. It is **excluded** from the
high-frequency dataset rather than null-padded into it — padding would invent a
regular series where none was observed, and every rolling feature computed over it
would be fiction.

---

## 7. CoinMarketCap credit budget

`quotes/latest` (v2) bills **1 credit per call per 100 cryptocurrencies returned,
per convert option**. Fifty ids in one batched call with `convert=USD` is
therefore **1 credit**, exactly as it is today with eleven ids — going from 11
assets to 50 costs nothing.

| | Now (Phase 3) | After Phase 5 |
|---|---|---|
| Cadence | every 5 min | hourly |
| Calls / month | 8,640 | **730** |
| Credits / call | 1 | 1 |
| Credits / month | 8,640 | **730** |
| Free tier (Basic) | 10,000 / month | 10,000 / month |
| **Quota used** | **86.4%** | **7.3%** |

The daily limit matters too: the Basic plan caps at ~333 credits/day, and hourly
polling uses **24**. Both ceilings are comfortable.

**The 92% of quota that is freed is deliberately left unspent.** Hourly is not the
budget ceiling — 15-minute polling would use 2,920 credits/month, still only 29% —
it is the correct *grain for the data*. Supply, rank and dominance move on
timescales of days; sampling them every five minutes stores the same number 12
times an hour and calls it data. Price is the fast-moving field, and price now
comes from the stream.

One consequence worth naming: market cap is `price × circulating_supply`, so
market cap *does* move fast even though supply does not. Rather than polling
CoinMarketCap for it, Gold reconstructs a high-frequency market cap as
`binance_price × circulating_supply_as_of`, with the assumption — supply constant
between hourly snapshots — stated in the column's documentation, and CoinMarketCap's
own hourly value kept alongside it as the check.

---

## 8. Binance WebSocket: the operational contract

Public market-data streams, **no API key and no rate-limit quota**. Endpoints:

- `wss://stream.binance.com:9443` / `wss://stream.binance.com:443`
- `wss://data-stream.binance.vision:443` — market-data only, no user-data streams
- Combined form: `/stream?streams=<s1>/<s2>/...`, payloads wrapped as
  `{"stream":"<name>","data":{...}}`. Stream names are **lowercase**.

Everything the producer must handle, and the state of the evidence for each:

| Rule | Value | Verified |
|---|---|---|
| Server sends a **ping** frame | every **20 s** | ✅ re-read from Binance docs, 2026-08-26 |
| Client must reply **pong** (copying the ping payload) | within **1 minute**, or the connection is dropped | ✅ 2026-08-26 |
| **Maximum connection lifetime** | **24 h**, then a forced disconnect | ✅ 2026-08-26 |
| **Connection attempts** | **300 per attempt every 5 minutes**, per IP | ✅ 2026-08-26 |
| **`serverShutdown` event** | sent before a planned shutdown; reconnect immediately | ✅ 2026-08-26 |
| Max **streams per connection** | 1,024 | ⚠️ carried from prior research; re-verify in Phase 5 |
| **Incoming** client messages | 5 / second (counts PING, PONG and JSON control frames); exceeding it disconnects, repeating it earns an IP ban | ⚠️ carried from prior research; re-verify in Phase 5 |

Consequences the producer design must absorb, none of them optional:

- **The 24-hour disconnect is a scheduled event, not a failure.** Reconnect must be
  routine and instrumented; if it only ever runs in the error path it will be
  untested when it first fires. Same for `serverShutdown`.
- **Reconnect with exponential backoff and jitter.** A fixed retry loop against a
  300-per-5-minutes ceiling turns a transient outage into an IP ban.
- **The 5-messages/second inbound limit governs subscription management.** With
  90 streams (§9) the subscription must go in the connect URL or be chunked, not
  sent as 90 individual `SUBSCRIBE` frames.
- **A gap must be recorded, not smoothed.** On reconnect, write an explicit
  connection-lifecycle event into the stream so a hole in the series is
  distinguishable in the data from a period of no trading.
- **1,024 streams on one connection is ample** for 90, so the design stays at a
  single connection — which also keeps ordering per symbol trivially intact.

---

## 9. Which streams, and what they cost

Everything here was **measured on the wire**, not estimated: a minimal WebSocket
client held a combined stream open for 60 s against BTCUSDT / ETHUSDT / ADAUSDT
and counted frames and bytes per stream, and the 45-pair trade totals come from
`ticker/24hr` (`.count` is the 24 h trade count).

| Stream | msg/s per symbol (BTC / ETH / ADA) | Bytes per frame |
|---|---|---:|
| `@bookTicker` | **123.5 / 51.3 / 12.1** | 146 |
| `@trade` | 57.1 / 17.9 / 1.1 | 168 |
| `@aggTrade` | 16.0 / 5.5 / 0.3 | 204 |
| `@kline_1m` | 0.5 / 0.5 / 0.2 | 360 |

Across the 45 streamed pairs, Binance reported **15,960,612 trades in 24 h** —
about **185 trade events per second**, BTCUSDT alone at 4.18 M.

**Recommended subscription: `@aggTrade` + `@kline_1m` on all 45 symbols.** 90
streams, against a 1,024-per-connection limit, ~70 records/second, ~47 GB/month.

- **`@aggTrade` rather than `@trade`.** Aggregate trades collapse fills of one
  taker order at one price into a single event. Measured **3.86× fewer frames**
  live on the wire, and 4.01×/4.69× on a replayed BTCUSDT/ETHUSDT minute via REST.
  At a one-minute modelling grain the information lost is nil.
- **`@kline_1m`** delivers OHLCV already bucketed with a `closed` flag — the exact
  grain Phase 7's features want, without reconstructing bars from ticks. It is also
  nearly free: 0.5 msg/s per symbol.
- **`@bookTicker` is NOT in the baseline.** An earlier draft of this section put it
  on the 8 beta anchors before it had been measured; measuring it reversed the
  recommendation. At **123.5 msg/s on BTCUSDT alone** it is 7.7× that symbol's
  `@aggTrade` rate, and BTC-only `@bookTicker` moves as much data per month as
  `@aggTrade` + `@kline_1m` across all 45 symbols combined. Full `@depth` is worse
  again and was never a candidate.
- **`@ticker`** is redundant: its 24 h rolling stats are derivable from the klines.

### Cost, and two findings for Phase 5

Kinesis Data Streams **on-demand rounds every record up to 1 KB**. Our frames are
146–360 bytes, so writing one record per event bills roughly **4× the bytes
actually sent**. Capacity mode changes the shape of the bill entirely: on-demand
charges per GB with that rounding *plus* $0.040/hour per stream; provisioned
charges per shard-hour *plus* 25 KB PUT payload units, and is barely sensitive to
volume at this scale.

Monthly, at measured volume, walking from the naive build to the tuned one:

| Build | rec/s | Payload | Billed | Total |
|---|---:|---:|---:|---:|
| `@trade` + `@kline` + `@bookTicker`(8), unbatched, on-demand | 766 | 318 GB | 2,064 GB | **$217.46** |
| …drop `@bookTicker` | 207 | 103 GB | 558 GB | $81.34 |
| …`@aggTrade` instead of `@trade` | 70 | 47 GB | 190 GB | $47.78 |
| …batch to ~5 KB records | 70 | 47 GB | 47 GB | $36.38 |
| …**1 provisioned shard instead of on-demand** | 70 | 47 GB | 47 GB | **$12.62** |

*(Kinesis + Firehose + S3. Excludes the producer host, which is Phase 5's open
decision at ~$10–15/month on Fargate.)*

**Finding 1 — the ingestion path, not the host, is where the money is.** Phase 5
frames its hosting decision around $10–15/month. Built naively the ingestion path
alone is **$217/month**; tuned it is **$12.62**. Same data, same 50 assets, 17×
apart — the difference is entirely in stream selection, batching and capacity mode.

**Finding 2 — `ON_DEMAND` looks like the wrong default for this workload.** Phase
5's scope specifies it. Measured throughput is **17.4 KB/s and ~70 records/s**,
against a single provisioned shard's 1 MB/s and 1,000 records/s — roughly 60× and
14× headroom. That shard is **$10.95/month flat**, against **$29.20/month in
on-demand stream-hour charges before a single byte is written**. On-demand earns
its premium on unpredictable spiky load; this load is small, and now measured.
**Not changed here — Phase 4 writes no Terraform — but Phase 5 should decide it
with these numbers rather than inherit the default.**

One consequence worth carrying forward: **on a provisioned shard, `@bookTicker`
becomes affordable again.** Provisioned bills 25 KB PUT units rather than GB, so
batched BTC+ETH `@bookTicker` adds roughly **$2/month** (and 25 KB/s, still well
inside one shard) versus well over $100/month unbatched on on-demand. If Phase 7
wants spread and microprice features, that is the door — and it is the capacity-mode
decision that opens it, not a data decision.

A third option was considered and rejected on architecture, not cost: the producer
could write **directly to Firehose** and skip Kinesis Data Streams entirely, for
roughly $1.50/month and no stream-hour charge. That deletes replay and multiple
independent consumers — precisely what Phase 13's feedback loop will need — so the
stream stays. The trade-off is recorded so the choice reads as deliberate.

---

## 10. The join between the two sources

**Decided: Silver stays source-separated; the join happens in Gold.**

Phase 2.1 left this open ("`cmc/` and `binance/`, until the Phase 4 join defines
the merged shape"). It is now settled, and the prefixes stay as they are:

| Layer | Shape |
|---|---|
| Bronze | `bronze/cmc/…` and `bronze/binance/…` — raw payloads, untouched |
| Silver | `silver/cmc/…` and `silver/binance/…` — two tables, each cleaned, typed and deduplicated against **its own** source |
| Gold | source-agnostic datasets. **Gold is the join** |

Why not merge in Silver:

1. **Silver's contract is "Bronze, cleaned and typed".** Merging two sources is a
   modelling decision, and modelling decisions belong in Gold. Keeping Silver
   faithful to its source is what makes it reprocessable.
2. **The grains do not match**, and forcing them to would destroy something. Joining
   at Silver means either downsampling the stream to hourly — throwing away the
   entire reason for Phase 5 — or upsampling CoinMarketCap to tick grain, which
   fabricates rows that were never observed.
3. **Blast radius.** If the CoinMarketCap payload shape changes, one Silver job is
   re-run. With a merged Silver, every reprocess touches both sources.
4. Phase 2.1 already committed to this when it made Gold's prefixes dataset names
   rather than source names, on the grounds that Gold "is already the join".

### How the join actually works: as-of, backward, on `cmc_id`

For each streaming row at time *t*, attach the **most recent CoinMarketCap snapshot
whose `event_time_utc <= t`**. A point-in-time (as-of / backward) join, never a
forward one — attaching a snapshot from the future is look-ahead leakage, and it
would make the model's backtest look excellent and its live performance not.

In Spark this is a broadcast of the small hourly table plus a
`last(... ignoreNulls = true)` over a window partitioned by `cmc_id` and ordered by
timestamp, after a union-and-sort. The mapping file is the third input, broadcast
as the bridge between `binance_symbol` and `cmc_id`.

Rules that make the join defensible rather than merely functional:

- **Staleness is a column, not a silence.** Every joined row carries
  `cmc_snapshot_age_seconds`. A snapshot older than a threshold (3 h — three missed
  hourly runs) sets `cmc_stale = true` rather than being forward-filled invisibly.
  A CoinMarketCap outage must not present itself as a frozen market cap that looks
  like real data.
- **The two prices never merge into one column.** `price_binance` and `price_cmc`
  stay separate. CoinMarketCap's price is a cross-exchange aggregate and Binance's
  is one venue's execution — collapsing them would silently mix two different
  measurements of two different things.
- **Their difference is a feature.**
  `price_divergence_bps = (price_binance − price_cmc) / price_cmc × 10⁴`,
  computed only at snapshot instants where both are genuinely observed. This is the
  cross-validation of §3 turned into a model input: single-venue dislocation,
  measured.
- **Derived high-frequency market cap** as described in §7, explicitly named as
  derived and kept beside the authoritative hourly value.
- **`has_stream = false` assets** flow into the hourly Gold datasets only. They are
  filtered by the config flag, not by a hardcoded exception list.
- **Event time lives inside the payload**, in UTC epoch milliseconds, never only in
  the S3 path. Phase 6 states this as non-negotiable and the join is why: the join
  predicate is on event time, and a path-derived timestamp is delivery time.
- **Deduplicate before joining.** Firehose delivery is at-least-once, so the
  streaming Silver table is deduplicated on `(binance_symbol, event_time, trade_id)`
  and the CoinMarketCap table on `(cmc_id, event_time_utc)` — which is what it
  already does today.

---

## 11. Historical backfill — stitching 2017 onto the stream

**The gap this closes.** Phases 7, 8 and 13 need years of data to train and to
measure degradation against. A streaming pipeline switched on in Phase 5 produces
*weeks*. Nothing in the roadmap addressed that until now.

Binance publishes its **entire kline history for free**, no key and no quota, at
`data.binance.vision` (monthly and daily ZIPs, each with a published SHA-256
`.CHECKSUM`). Verified against the live archive on 2026-08-27:

| | |
|---|---:|
| Asset-months of 1-minute history across the 45 streamed pairs | **3,036** |
| …including the pre-rename aliases (§6) | **3,135** |
| 1-minute candles | **~133 million** |
| Compressed download | **~4.4 GB** |
| Cost | **$0** |

It never touches Kinesis or Firehose — it is downloaded and written straight to
S3, so none of the §9 cost analysis applies to it.

### Why 2017, and why that is the right floor anyway

**There is no 13-year history to fetch, for any asset.** Binance opened in July
2017, so its archive starts there and nowhere earlier:

| Pair | First candle |
|---|---|
| `ETHBTC`, `LTCBTC`, `BNBBTC` | 2017-07 |
| `BTCUSDT`, `ETHUSDT` | 2017-08 |
| `LTCUSDT` | 2017-12 |

That floor is a feature, not a limitation. Pre-2017 crypto is not merely quiet —
it is **a different market**: no institutions, no meaningful derivatives, volumes
orders of magnitude smaller, and the price discovery happening on venues that no
longer exist. A model trained across that boundary learns a market that is gone.
The data availability and the useful history begin at the same date, which is
convenient rather than coincidental.

### The stitch is exact, not an approximation

This is the part that makes the whole idea work, and it is worth being precise
about. The archived monthly file and the live `@kline_1m` stream are **the same
twelve fields, computed by the same exchange, over the same one-minute bucket**:

```
open_time, open, high, low, close, volume, close_time, quote_asset_volume,
number_of_trades, taker_buy_base_volume, taker_buy_quote_volume, ignore
```

A real row, `BTCUSDT-1m-2018-01.csv`:

```
1514764800000,13715.65,13715.65,13681.00,13707.92,2.844266,1514764859999,
38931.00441306,32,2.002554,27414.35411530,0
```

The WebSocket `@kline_1m` payload carries the identical set (`o,h,l,c,v,q,n,V,Q`
plus the `x` closed flag). So the join between old and new is **field-for-field**,
not a reconstruction that has to be trusted. This is the strongest argument for
keeping `@kline_1m` in the §9 baseline: it costs 0.5 msg/s per symbol and it is
what makes 2017 and today the same table.

Two things fall out of those twelve columns that are easy to miss:

- **`number_of_trades` and the taker-buy volumes are order flow, available
  historically.** `taker_buy_base_volume / volume` is the share of the minute's
  volume that was aggressive buying — a genuine imbalance feature, and it exists
  back to 2017. The backfill is materially richer than plain OHLCV.
- **`aggTrade` archives exist too, and are not worth it.** One month of BTCUSDT
  aggTrades is **362 MB compressed**, against 2.1 MB for the same month of
  1-minute klines. Backfill with klines.

### What the backfill does NOT give

- **No tick-level detail.** Sub-minute features exist only from Phase 5 forward.
  The feature set in Phase 7 must therefore be **layered**: a core block computable
  from 1-minute OHLCV alone, spanning 2017→now, and a separate tick-derived block
  that starts when the stream does. Mixing them into one flat schema produces a
  dataset that is 90% null in its most interesting columns.
- **Not a dense grid.** `BTCUSDT-1m-2018-01.csv` holds **44,515 rows against the
  44,640 minutes** in January 2018. Binance's own history has gaps — maintenance
  windows, halts. The Gold job must treat a missing minute as missing, never
  forward-fill it into existence.
- **Not a rectangular panel.** Only BTC and ETH reach 2017. XAUt has **7 months**;
  ONDO 18; PENGU 22. Any feature that requires all 50 assets present will silently
  truncate the dataset to the youngest one.
- **Nothing for the five CMC-only assets**, by definition — and `XMRUSDT`'s
  history simply *stops at 2024-02*, which is the delisting, visible in the data.

### Two decisions this forces

**1. Provenance is a column.** Every row carries `source ∈ {backfill, stream}`.
The two halves come from the same exchange and the same definition, but they
arrive by different paths, and a bug in one must be attributable. In the overlap
window — the backfill can be re-downloaded for months the stream already covered —
the reconstructed and archived bars should be compared field by field. If they do
not match, the producer is wrong, and that check is only possible because the
grain and the schema are identical.

**2. Renames must be stitched, or months vanish silently.** §6's symbol traps have
a data consequence here, not just a join one:

| Asset | Current pair | Earlier pair | Lost if ignored |
|---|---|---|---|
| RENDER | `RENDERUSDT` 2024-07 → (27 mo) | `RNDRUSDT` 2021-11 → 2024-07 (33 mo) | **33 months** |
| POL | `POLUSDT` 2024-09 → (25 mo) | `MATICUSDT` 2019-04 → 2024-09 (66 mo) | **66 months** |

Downloading only the current ticker returns a clean-looking file that is missing
more history than it contains. `config/tracked_assets.json` therefore carries
`binance_symbol_aliases` per asset, and the backfill job reads it.

### Optional: the BTC-quoted pairs go deeper

Binance launched with BTC-quoted markets; USDT pairs came later. For the older
assets the `…BTC` pair reaches further back:

| Asset | `…USDT` from | `…BTC` from | Extra |
|---|---|---|---:|
| ZEC | 2019-03 | 2017-11 | **+16 mo** |
| LINK | 2019-01 | 2017-09 | **+16 mo** |
| XMR | 2019-03 | 2017-11 | **+16 mo** |
| ETC | 2018-06 | 2017-10 | +8 mo |
| XRP | 2018-05 | 2017-11 | +6 mo |
| LTC, ADA | 2017-12 / 2018-04 | 2017-07 / 2017-11 | +5 mo |

Using them means synthesising a USD series — `price_usd = price_btc ×
BTCUSDT_close` on the same minute — which compounds two series' noise and leans on
early BTC-pair liquidity that was thin. **Recommendation: USDT pairs are the
primary source; BTC-quoted pairs are an optional pre-2019 deepening, flagged with
their own provenance value and never mixed in silently.**

### One honesty caveat, stated rather than hidden

The 50 assets were chosen in 2026, knowing which ones survived. Training over
2017–2026 on that list embeds hindsight: it contains no asset that was prominent in
2018 and is now dead. This is inherent to any fixed universe and it is not being
solved here — it is being **named**, because a backtest over this dataset is a
technical demonstration and not evidence of a tradeable strategy, exactly as this
project's stated goal says.

---

## 12. What Phase 5 inherits from this

Concretely, and nothing more than this:

- `config/tracked_assets.json` is the single source of truth. Terraform reads the
  id list from it instead of holding a literal in tfvars —
  `tracked_asset_ids = [for a in jsondecode(file("${path.module}/../../../config/tracked_assets.json")).assets : a.cmc_id]`
  — which applies to the asset list the same rule Phase 2.1 applied to bucket names
  and Phase 3 applied to job names: one owner per fact.
- The producer reads the same file for its subscription list, filtered on
  `has_stream`.
- The CoinMarketCap Lambda goes from `rate(5 minutes)` to `rate(1 hour)` and picks
  up 50 ids instead of 11, at no extra credit cost.
- The `ON_DEMAND` question in §9 gets re-examined against the measured numbers.
- **No Terraform was changed in Phase 4** and the project is still dormant. The
  wiring above is Phase 5's work, described here so it is not re-derived.

---

## 13. Reproducing the verification

Every number in this file comes from one of these, all free and unauthenticated:

```bash
# Binance: which USDT spot pairs are actually TRADING
curl -s https://api.binance.com/api/v3/exchangeInfo \
  | jq -r '.symbols[] | select(.quoteAsset=="USDT" and .status=="TRADING" and .isSpotTradingAllowed) | .baseAsset'

# Binance: 24 h volume and trade counts per pair  (.count is the trade count)
curl -s https://api.binance.com/api/v3/ticker/24hr | jq -r '.[] | [.symbol,.quoteVolume,.count] | @tsv'

# Binance: aggTrade compression, measured on a real minute
curl -s "https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1m&limit=1"      # [8] = raw trade count
curl -s "https://api.binance.com/api/v3/aggTrades?symbol=BTCUSDT&limit=1000" | jq length

# Binance: which of the tracked assets Binance carries at all, and in what state
#   BREAK = existed and was halted (delisted);  no row = never listed
curl -s https://api.binance.com/api/v3/exchangeInfo \
  | jq -r '.symbols[] | select(.baseAsset=="XMR" or .baseAsset=="DAI") | [.symbol,.status] | @tsv'

# Binance: how far back the archive reaches for a pair (interval=1M, startTime=0)
curl -s "https://api.binance.com/api/v3/klines?symbol=LTCUSDT&interval=1M&startTime=0&limit=1000" \
  | jq -r 'length as $n | "\(.[0][0]|tonumber/1000|todate) .. \($n) months"'

# Binance: the free historical archive, with its published checksum
curl -sI https://data.binance.vision/data/spot/monthly/klines/BTCUSDT/1m/BTCUSDT-1m-2018-01.zip
curl -s   https://data.binance.vision/data/spot/monthly/klines/BTCUSDT/1m/BTCUSDT-1m-2018-01.zip.CHECKSUM

# CoinMarketCap ids and market caps, WITHOUT spending API credits
curl -s -H 'User-Agent: Mozilla/5.0' \
  'https://api.coinmarketcap.com/data-api/v3/cryptocurrency/listing?start=1&limit=200&sortBy=market_cap&sortType=desc&convert=USD' \
  | jq -r '.data.cryptoCurrencyList[] | [.id,.symbol,.name] | @tsv'
```

The per-stream message rates and frame sizes in §9 needed a real WebSocket client,
not REST: a ~60-line raw RFC 6455 client (TLS socket, HTTP upgrade, frame parsing,
pong on ping) held a combined stream open for 60 s and counted frames per stream
name. Worth keeping in mind if these numbers are ever re-checked — `@bookTicker`'s
rate in particular is invisible from REST, and it was measuring it that reversed
the recommendation to include it.

The project's own CoinMarketCap key was **not** used, and no credits were spent:
the public listing endpoint above carries the ids, and the pro API adds nothing
that curation needed. The AWS CLI was not needed at any point either, which is the
correct property for a phase that changes no infrastructure.

---

*Market context data provided by [CoinMarketCap.com](https://coinmarketcap.com);
market data from Binance public endpoints. Used for R&D and educational purposes.*
