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

