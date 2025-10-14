# 🥇 Milestone — Gold Layer Design

## 🎯 Overview

The **Gold Layer** represents the final stage of the **Medallion Architecture** in the **Near Real-Time Crypto Ingestion** project.  
At this level, clean and normalized data from the Silver layer is transformed into **high-value analytical datasets** — ready for **Machine Learning**, **dashboards**, and **time-series analysis**.

This layer is structured into **three specialized sublayers**, each with a clear purpose, and implemented as **logical views** instead of multiple physical tables to avoid data duplication and reduce costs.

---

## 🧱 General Structure

The Gold layer is divided into three main components:

| Sub-Layer | Description | Frequency | Main Purpose |
|------------|--------------|------------|----------------|
| **Gold Features Base** | Cleansed and enriched dataset containing validated metrics and quality checks | Daily (per asset_id) | Core source of truth for analytics |
| **Gold OHLC (H/D/W/M)** | Aggregated *Open–High–Low–Close* time-series | Hourly, Daily, Weekly, Monthly | Market visualization and time-series analysis |
| **Gold ML Training** | Engineered dataset for model training | Daily | ML-ready dataset for forecasting and classification |

Instead of creating three separate Glue tables, we defined **logical Athena views** on top of the same Parquet files.  
This design reduces crawling overhead and simplifies schema maintenance.


## 🧩 1. Gold Features Base

**Source:** [`gold_features_base_job.py`](./glue_jobs_silver_gold/gold/gold_features_base_job.py)

---

### 🎯 Purpose

To **normalize**, **validate**, and **enrich** the Silver dataset before any downstream analytical or Machine Learning tasks.

---

### ⚙️ Key Operations

- **Explicit casting** of all columns for schema stability.  
- **Deduplication** by `(asset_id, event_time_utc)` → keeping the latest by `ingestion_ts_utc`.  
- **Derived columns:**
  - `turnover_24h` → ratio between traded volume and circulating supply.  
  - `market_cap_check_gap_pct` → relative difference between reported and computed market cap (`price_usd * circulating_supply`).  
- **Partitioning:** by `dt` and `asset_id` for efficient reads and parallelism.  
- **Compression:** `snappy` codec with dynamic overwrite to support incremental writes.

---

### 🧠 Role

Acts as the **core analytical dataset**, feeding both the **Gold OHLC** and **Gold ML Training** layers.


## 📊 2. Gold OHLC (H/D/W/M)

**Source:** [`gold_ohlc_h_d_w_m.py`](./glue_jobs_silver_gold/gold/gold_ohlc_h_d_w_m.py)

---

### 🎯 Purpose

To generate **time-aggregated series** for financial-style analysis — specifically the **Open, High, Low, Close (OHLC)** pattern — across multiple granularities (`hour`, `day`, `week`, `month`).

---

### ⚙️ Key Operations

- **Period definition** using `date_trunc(GRAIN)`, where `GRAIN ∈ {hour, day, week, month}`.  
- **Window calculations:**
  - `open`, `close` → first and last prices within the period.  
  - `high`, `low` → max and min prices.  
  - Also calculated for `market_cap`.  
- **Validation metrics:** number of ticks and valid tick ratios (`n_ticks`, `valid_ticks`).

---

### 🧠 Role

Feeds **visual dashboards** (e.g., QuickSight) and **technical market analysis**, providing a **clean and consistent time-series foundation**.


## 🧠 3. Gold ML Training

**Source:** [`gold_ml_training_job.py`](./gold_ml_training_job.py)

---

### 🎯 Purpose

To **engineer predictive features and target variables** for supervised learning models (e.g., price prediction or uptrend classification).

---

### ⚙️ Key Metrics and Features

| Category | Feature | Description |
|-----------|----------|-------------|
| **Returns** | `ret_1d`, `ret_3d`, `ret_7d`, `ret_14d`, `ret_30d` | Log returns over multiple windows. |
| **SMA Ratios** | `sma_5_over_20` | Ratio between short- and long-term moving averages — momentum indicator. |
| **Volatility** | `vol_3d`, `vol_7d`, `vol_14d`, `vol_30d` | Standard deviation of daily log returns — short vs. long volatility. |
| **Volume Features** | `vol_chg_1d`, `vol_z_14d` | Daily volume change and 14-day z-score deviation. |
| **Market Dynamics** | `mcap_chg_1d`, `mcap_dom_chg_1d`, `supply_utilization` | Market cap variation, dominance delta, and circulating/max supply ratio. |
| **Cross Factors** | `ret_mkt_1d`, `ret_btc_1d` | Market-wide and Bitcoin benchmark returns. |
| **Rankings** | `rank_mcap`, `rank_momentum_7d` | Daily market cap and momentum ranks. |
| **Calendar Flags** | `dow`, `is_month_end` | Weekday and month-end flags for seasonal effects. |
| **Data Quality** | `missing_7d`, `missing_30d` | Count of missing data points (avoid leakage). |
| **Targets** | `y_ret_1d_fwd`, `y_up_1d_2pct` | Forward 1-day log return and binary label (“price up ≥ 2%”). |

---

### 🧠 Role

Provides a **machine-learning-ready dataset** for training and validation of predictive financial models.

---

## 🧮 4. Why Views Instead of Physical Tables

Instead of materializing three separate Glue tables, **Athena logical views** were used for each Gold sublayer.

### Reasons

- **No data duplication:** all views share the same physical Parquet files.  
- **Simpler catalog maintenance:** only one crawler is required for the Gold bucket.  
- **Schema flexibility:** structural updates propagate automatically.  
- **Cost-efficient:** less storage, shorter crawl times, and faster updates.

---

## 🪄 5. Partition Projection (Athena Optimization)

### 🧩 Challenge

With multiple partition keys (`dt`, `asset_id`, `g`), continuously running Glue Crawlers would be slow and expensive.

### 💡 Solution

**Athena Partition Projection** was implemented to infer partitions dynamically at query time — eliminating the need for crawler updates.

### 🚀 Benefits

- **Zero crawler cost:** Athena automatically interprets partition keys.  
- **Instant querying:** data available immediately after job completion.  
- **Highly scalable:** supports thousands of assets and daily updates.  
- **Ideal for near-real-time ingestion**, removing delay between ingestion and analysis.

---

### 🧱 Example Configuration

```sql
projection.enabled = true
projection.dt.type = date
projection.dt.range = '2024-01-01','NOW'
projection.asset_id.type = integer
projection.asset_id.range = 1,500
storage.location.template = s3://lake-curated-data-silver-gold-crypto/top10/gold/features_base/dt=${dt}/asset_id=${asset_id}/
```

## 🧭 Conclusion

The **Gold Layer** of the **Near Real-Time Crypto Ingestion** project embodies a **modular**, **analytics-driven**, and **ML-ready** design that:

- Maintains a **single, consistent data lake** with no redundancy.  
- Enables **deep analysis** of price, volume, and volatility across granularities.  
- Produces **auditable and trainable datasets** for real financial modeling.  
- Leverages **Partition Projection** and **Athena Views** for **high-performance, low-cost scalability**.


## 🔄 Design Update — Gold OHLC Now Reads from Gold Features Base

### 🧠 Context

Originally, the **Gold OHLC Glue Job** sourced its data directly from the **Silver layer**, because at that time the **Gold Features Base** was still under active development.  
This decision helped decouple the OHLC job during early stages — allowing progress while the schema and deduplication logic of Features Base were still stabilizing.

However, once **Gold Features Base** became the canonical and validated dataset, the architecture was updated to make OHLC depend on it instead of Silver.

---

### ⚙️ Implementation Changes

| Component | Old | New |
|------------|-----|-----|
| **Input Path** | `s3://<silver-bucket>/<silver-prefix>/` | `s3://<gold-bucket>/<gold_features_prefix>/` |
| **Deduplication Block** | Required | Removed (already handled in Features Base) |
| **Schema Casting** | Defensive only | Maintained for safety |
| **Partitioning** | `g / dt / asset_id` | Same (no change) |

---

### ✅ Reasons for the Change

**1. Single Source of Truth:**  
Gold Features Base already performs deduplication and type normalization, ensuring all downstream layers use consistent and validated data.

**2. Data Quality:**  
Prevents discrepancies between OHLC, ML Training, and Features datasets by basing all three on the same validated source.

**3. Performance:**  
Avoids redundant deduplication logic and reduces Glue compute time.

**4. Consistency with Medallion Principles:**  
- **Silver →** semi-clean, operational layer.  
- **Gold →** analytical and ML-ready layer.  
- Within Gold, **Features Base** acts as the foundation for both **OHLC** and **ML Training**.

**Resulting Flow**
```
Silver  ──▶  Gold Features Base  ──▶  Gold OHLC
                               └──▶  Gold ML Training
```

- OHLC and ML Training now share the same foundation (validated metrics and schema).
- Athena Views and Partition Projection remain identical — only the upstream source changed.
- The pipeline is now fully modular, crawlerless, and schema-consistent across all analytical layers.