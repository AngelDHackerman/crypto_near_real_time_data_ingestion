## 🚧 Challenges Overcome

### 1. Raw Partitioning Strategy (ID → Date)
**Challenge:**  
When designing the raw landing zone, the question was how to partition the files in S3. If we placed dates first and IDs second, querying a single asset (e.g., BTC) required scanning many folders and wasted resources.

**Solution:**  
Partition the raw data by `id` first and then by `year/month/day/hour`:

`s3://.../bronze/id=1/year=2025/month=09/day=28/hour=03/part-*.json`


**Impact:**  
- Easy isolation of each asset.  
- Optimized scans in Athena/Glue when filtering by a specific `asset_id`.  
- Preserved hourly granularity for time-series analysis.  

---

### 2. Silver Partitioning Strategy (Date → ID)
**Challenge:**  
In the Silver layer, the focus is on analytical queries (Athena, QuickSight). Keeping the raw-style partitioning (`id → date`) made time-based queries inefficient.

**Solution:**  
Partition Silver first by `date` (`y/m/d/h`) and then optionally by `asset_id`:

`s3://.../silver/year=2025/month=09/day=28/hour=03/asset_id=1/part-*.parquet`


**Impact:**  
- Faster time-range queries (the most common in financial analytics).  
- Maintained flexibility to filter by asset if needed.  
- Turned the Silver layer into an analytics-optimized data lake.  

---

### 3. Data Normalization in RAW (Union Types Problem)
**Challenge:**  
The CoinMarketCap API sometimes returns the same field with different types across calls. For example:  

- `fully_diluted_market_cap` as `long` in some responses, `double` in others.  

- Glue/Spark inferred this as a **union struct** (`struct<double:double, long:bigint>`), which caused runtime errors such as:  

`AnalysisException: need struct type but got double`


**Solution:**  
Normalize types directly in the **Lambda Extractor** before writing to S3.  
- Implemented `_normalize_coin_types` to force all numeric metrics (`price`, `market_cap`, `supplies`, etc.) to **float**.  
- Ensured consistent schema across all assets and all files.

**Impact:**  
- Simplified and stabilized the Silver Glue job (fewer fallbacks needed).  
- Removed `NaN` issues and union-related errors.  
- Produced homogeneous data, ready for ML, Athena, and QuickSight.  

---

### 4. Avoiding the Small Files Problem
**Challenge:**  
Without care, each asset/hour combination could generate a separate Parquet file. This would lead to thousands of very small files, slowing down Athena and increasing query costs.

**Solution:**  
Repartition the Silver output by `y/m/d/h` (and optionally `asset_id`) so that **all 11 assets for the same hour are written into a single Parquet file**.

**Impact:**  
- Prevented the *small files problem*.  
- Reduced the number of files scanned per query.  
- Lowered costs and improved performance for downstream analytics.  

---

### 5. Manifest and Status Folders in RAW
**Challenge:**  
Our ingestion Lambda also stored `manifest/` (list of ingested IDs) and `status/` (API diagnostics) objects in the same Raw bucket.  
Initially, the Glue Silver job tried to parse these files as if they were asset JSON, which caused schema mismatches, missing fields, and spurious rows.

**Solution:**  
Exclude these folders explicitly in the Glue job’s read options:
```python
"exclusions": ["**/manifests/**", "**/status/**"]
```

---

### 6. Migration to Partition Projection (Crawlerless Architecture)
**Challenge:**  
The Gold layer originally depended on AWS Glue Crawlers to discover new partitions daily (`dt` and `asset_id`).  
However, this approach introduced several issues:
- Crawlers frequently re-inferred wrong column types (`dt` and `asset_id` as `string` instead of `date`/`int`).  
- Periodic crawls added unnecessary latency and cost.  
- When a DDL-created table already existed, Glue created duplicate tables with random hash suffixes.  

**Solution:**  
Replaced Crawlers entirely with **Athena Partition Projection**, a feature that dynamically infers partitions based on predictable S3 paths.  
Configured the Gold tables (`gold_features_base`, `gold_ml_training`) with `projection.*` properties and a `storage.location.template`:

```sql
ALTER TABLE crypto_gold_db.gold_features_base SET TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.dt.type'='date',
  'projection.dt.range'='2025-10-01,NOW',
  'projection.dt.format'='yyyy-MM-dd',
  'projection.asset_id.type'='integer',
  'projection.asset_id.range'='1,9999',
  'storage.location.template'='s3://lake-curated-data-silver-gold-crypto/top10/gold/gold_features_base/dt=${dt}/asset_id=${asset_id}/'
);
```

**Impact:**

* 🕒 Zero delay — Athena instantly recognizes new data as soon as Glue Jobs write to S3.
* 💰 Zero cost — no recurring crawler or MSCK REPAIR operations.
* ⚙️ Full IaC control — schema and partition logic now live entirely in Terraform/DDL, ensuring reproducibility.
* 🧠 Type accuracy — dt is enforced as DATE and asset_id as INT, preventing schema drift.

**Result:**

The Gold layer is now **fully crawlerless** and self-updating — a real-time, serverless, and cost-efficient architecture aligned with modern Data Lakehouse best practices.

---

### 📌 Lessons Learned
- **Design partitions with consumers in mind**: in Raw we optimize for asset isolation, in Silver we optimize for time-based analytics.  
- **Normalize early**: cleaning types at ingestion time prevents schema chaos later.  
- **Document decisions**: each technical challenge turned into a learning milestone.  
- **Think about file sizes**: grouping multiple assets per hour avoids small files, improving query performance and cost efficiency.  
