EventBridge + Lambda + S3 + Athena + IAM + CloudWatch & Terraform

This is a **datalake medallion architecture**

las particiones son por hora de ingesta, no por hora de origen


[crypto price endpoint](https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest)


Name            ID
Bitcoin         1
Etherium        1027 
XRP             52
Tether          825
BNB             1839
Solana          5426
USDC            3408
Dogecoin        74
Cardano         2010
Tron            1958
BAT             1697


Usar estructura Bronze: texto crudo, Silver: texto limpio y procesado & Gold: informacion valiosa para el ML 

* lambda para bronze 
* glue job para el transformer (silver)
* glue job para feature basicos (retornos, vol, momentum) (gold)
* glue crawler: actualizar Data Catalog 3 tablas: bronze_top10, silver_top10, gold_top10_features
* Athena/SageMaker consumen informacion. 

1. idempotencia & deduplicacion:
    * Usa en S3 claves únicas con timestamp del proveedor: bronze/yyyymmdd/hh/mm=MM/cmc_ts=2025-09-18T02:50:00Z.json
    * Antes de escribir a silver/gold, dedup por (asset_id, last_updated).
2. esquema y particionado: 
    * Particiona por fecha/hora y symbol: silver/dt=YYYY-MM-DD/hour=HH/symbol=BTC/part-*.parquet
    * Clave primaria “lógica”: (asset_id, as_of_ts, currency='USD').


## Data groups for ml_training table in gold data

1) Lagged returns & momentum (predictive baseline)
    * `ret_1d`, `ret_3d`, `ret_7d`, `ret_14d`, `ret_30d` (log returns)
    * Momentum ratios: `sma_5` / `sma_20`, `ema_12` / `ema_26`
    * __Why?__ Crypto exhibits short-to-medium momentum and mean-reversion patches.

2) Volatility & dispersion
    * Rolling stdev of returns: `vol_3d`, `vol_7d`, `vol_14d`, `vol_30d`
    * Rolling EWMA volatility: `vol_ewma_14`
    * __Why?__ Regime detection; higher vol often alters directional odds.

3) Volume, turnover & liquidity pressure
    * `volume_24h` (level), `vol_chg_1d` (Δ vs t-1), `vol_z_14d` (z-score)
    * `turnover_24h` (already in Gold Feature Base) & its rolling mean/stdev
    * __Why?__ Spikes in activity frequently precede larger moves.

4) Market-cap & dominance dynamics
    * `mcap_chg_1d`, `mcap_dom_chg_1d` (Δ dominance vs t-1)
    * `supply_utilization = circulating_supply / max_supply`
    * __Why?__ Cross-asset rotation and dominance shifts carry signal.
    
5) Cross-sectional market factors: Compute daily factors from the cross-section (Top-10/11):
    * __Market return__ (cap-weighted): `ret_mkt_1d`
    * __BTC factor__: yesterday’s BTC return `ret_btc_1d`
    * __Rolling correlation with BTC__: `corr_30d_to_btc`
    * __Within-day rank__: `rank_mcap`, `rank_momentum_7d` (1=largest/best)
    * __Why?__ Many alts co-move with “market” and BTC; beta & rank are useful.

6) Seasonality / calendar
    * `dow` (day of week one-hot), `is_month_end` (0/1)
    * __Why?__ Mild day-of-week & turn-of-month effects show up in crypto too.

7) Stability / quality flags
    * Missingness counts in last 7/30 days, large gap flags
    * __Why?__ Protect models from artifacts or thin assets.

All rolling features must be computed per asset_id ordered by dt, and only with past data (no leakage!).


Data provided by [CoinMarketCap.com](https://coinmarketcap.com). This data is used solely for internal research and development (model training and visualization). Raw data is not redistributed or published.


