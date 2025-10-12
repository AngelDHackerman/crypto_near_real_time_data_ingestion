# 🥉 Milestone — Bronze Layer Design

## 🎯 Overview

The **Bronze Layer** is the **entry point** of the Near Real-Time Crypto Ingestion pipeline.  
It captures raw responses directly from the **CoinMarketCap API** and stores them in S3 in a fully traceable, append-only format.  

Unlike the Silver and Gold layers, Bronze focuses on **data integrity and recoverability**, not analytics performance.  
It serves as the **immutable source of truth** for the entire lakehouse.

---

## ⚙️ Ingestion Logic

**Source:** [`app.py`](./app.py)

### Workflow Summary

1. **Secrets Management:**  
   The AWS Lambda function retrieves the API key from **AWS Secrets Manager** (`SECRET_ARN`).

2. **Batch Fetch:**  
   The function calls the **CoinMarketCap API** endpoint  
   `https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest`  
   passing a list of top asset IDs (via the environment variable `TOP_LIST_ID`).

3. **Normalization:**  
   Before writing, each JSON response is normalized to:
   - Ensure all numeric fields are cast to `float`.
   - Flatten nested `quote.USD` metrics.
   - Keep structure consistent across all assets and timestamps.

4. **Storage in S3:**  
   Each API response is stored as an individual JSON file under a **partitioned structure**:

```md
s3://<RAW_BUCKET>/<BRONZE_PREFIX>/
id=<asset_id>/
year=<YYYY>/
month=<MM>/
day=<DD>/
hour=<HH>/
part-<epoch>-<sha1>.json
```


5. **Manifest and Status Tracking:**  
For every batch, two additional JSON files are written:
- `/manifests/` → describes which assets were fetched and written.
- `/status/` → captures the CoinMarketCap API status and metadata.

---

## 🧱 Partitioning Structure

| Level | Key | Purpose |
|--------|-----|----------|
| 1 | `id` | Separates assets (BTC, ETH, etc.) |
| 2 | `year`, `month`, `day`, `hour` | Time-based hierarchy for easy backfills |
| 3 | `part-*` | Unique files per 5-minute batch |

**Example Path:**

```md
s3://lake-raw-data-bronze-crypto/top10/bronze/id=1/year=2025/month=10/day=12/hour=08/part-1734021453-abc123.json
```


### ✅ Advantages
- Enables **reprocessing of a specific hour or asset** without touching others.
- Simplifies **parallel Lambda execution** (no S3 write conflicts).
- Preserves **100% raw fidelity** (exact response from the API).

---

## 🔧 Normalization and Data Quality

**Function:** `_normalize_coin_types(coin_obj)`

The normalization logic ensures consistent types and schema before persistence:

| Field Group | Example Fields | Action |
|--------------|----------------|--------|
| Root-level floats | `circulating_supply`, `max_supply`, `total_supply` | Cast to float |
| USD quote metrics | `price`, `volume_24h`, `percent_change_*`, `market_cap`, `tvl` | Cast to float |
| Nested fields | `quote.USD.price` | Normalized and kept as numeric |
| Strings and tags | untouched | Preserve original structure |

### Benefits
- Prevents schema evolution conflicts in AWS Glue.  
- Simplifies downstream parsing (Silver job can assume clean JSON).  
- Reduces Glue DPU costs due to schema stability.

