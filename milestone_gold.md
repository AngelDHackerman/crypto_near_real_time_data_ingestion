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

