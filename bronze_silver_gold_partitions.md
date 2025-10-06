# 🧩 Partitioning Strategy Rationale (Bronze → Silver → Gold)

**Context:**  
This section explains why each layer of the **Near Real-Time Crypto Data Ingestion Pipeline** uses a different partitioning strategy and how this design improves scalability, cost efficiency, and analytical performance across AWS Glue, Athena, and S3.

---

## 📘 Overview

- Each layer in the data lake serves a **different purpose**, so the partitioning design also differs.  
- This is a **common and recommended practice** in production-grade data engineering pipelines following the **Medallion Architecture (Bronze → Silver → Gold)**.  
- In short:

| Layer  | Purpose | Partition Grain | File Format | Write Mode | Consumer |
|--------|----------|------------------|--------------|-------------|-----------|
| **Bronze** | Raw ingestion | `asset_id / year / month / day / hour` | JSON | Append | ETL & Audit |
| **Silver** | Cleaned hourly data | `y / m / d / h` | Parquet | Append | Glue / Athena |
| **Gold** | Analytical features | `dt / asset_id` | Parquet | Overwrite | Athena / ML |

---

## 🪣 Bronze Layer – *Ingestion Grain*

**Example Path:**

s3://lake-raw-data-bronze-crypto/top10/bronze/

id=<asset_id>/

year=<YYYY>/

month=<MM>/

day=<DD>/

hour=<HH>/

part-*.json



### 🎯 Purpose
The **Bronze** layer captures **exactly what the source system emits**. It reflects the *ingestion grain* — data is stored at the **same granularity** it arrives (every 5 minutes).

### 🧠 Why so granular?
- **Lossless capture:** Keeps the full fidelity of raw API responses.
- **Easy backfills:** You can reprocess just `id=1/year=2025/month=10/day=05/hour=15` if needed.
- **Parallel ingestion:** Each hour/asset prefix can be written independently, preventing S3 write contention.
- **Operational recovery:** Allows isolated corrections or retries for a specific hour/asset.

### ⚠️ Trade-offs
- Produces many **small JSON files**.
- Not query-optimized, but ideal for **traceability and reprocessing**.

---

## ⚙️ Silver Layer – *Curation Grain*

**Example Path:**

s3://lake-curated-data-silver-gold-crypto/top10/silver/

y=<YYYY>/m=<MM>/d=<DD>/h=<HH>/

part-*.snappy.parquet



### 🎯 Purpose
The **Silver** layer transforms the raw JSON into typed, validated Parquet files.  
It represents an **hourly roll-up** — each file contains all 5-minute intervals within that hour.

### 🧠 Why this partitioning?
- Aligns with **operational cadence** (data arrives every 5 minutes → stored hourly).  
- **Reduces small files**: 288 → 24 files per day per table.  
- Enables **partial rebuilds** (you can fix or reprocess only one hour).  
- Maintains a balance between write efficiency and query flexibility.

### 💡 Key Concept: *“Silver = ingestion grain”*
This layer is optimized for **data engineering convenience** — it still preserves time-based structure for operational debugging, but already provides **columnar and compressed Parquet** for downstream analytics.

---

## 🧮 Gold Layer – *Consumption Grain*

**Example Path:**

s3://lake-curated-data-silver-gold-crypto/top10/gold/gold_features_base/

dt=<YYYY-MM-DD>/

asset_id=<id>/

part-00001-...snappy.parquet



### 🎯 Purpose
The **Gold** layer is the **consumption-ready dataset** — clean, deduplicated, and optimized for analytical and ML workloads.

### 🧠 Why partition by `dt` and `asset_id`?
- Mirrors **how data is consumed**, not how it arrives.  
  Most queries filter by *date* and *asset*:
  ```sql
  SELECT *
  FROM crypto_gold_db.features_base
  WHERE dt = '2025-10-03' AND asset_id = 1;
  ```  
- Using: 
  ```python
  df_out.repartition("dt", "asset_id")
      .write.mode("overwrite")
      .partitionBy("dt", "asset_id")
  ```

creates one consolidated Parquet file per (date, asset).

## ⚙️ Result

- **Only one file per asset per day** (288 five-minute points consolidated).  
- **No small files problem.**  
- **Athena scans are faster and cheaper.**  
- **Dynamic partition overwrite** updates only modified partitions, not the entire table.  

---

## 🔥 Why Different Partitions per Layer?

| Layer | Partition Pattern | Purpose | Benefit |
|--------|------------------|----------|----------|
| **Bronze** | `id/year/month/day/hour` | Ingestion grain | Reprocessing, audit, replay granularity |
| **Silver** | `y/m/d/h` | Hourly curation | Balanced for ETL and Athena |
| **Gold** | `dt/asset_id` | Consumption grain | Query and ML optimization |

---

## ✅ Advantages of Using Different Partition Grains

- **Purpose-aligned design:** Each layer optimized for its role (capture → clean → consume).  
- **Faster queries:** Gold partitions directly match typical analytical filters.  
- **Operational isolation:** Fixing an upstream hour/day doesn’t impact consumer data.  
- **Cost efficiency:** Less data scanned per Athena query.  
- **Better scalability:** Distributed writes upstream, consolidated reads downstream.  

---

## 🧊 Avoiding Hot Partitions

**Hot partition** = when too many writers append to the same partition key at once.

### Bronze
- Writes distributed across `id/year/month/day/hour`.  
- Each key receives few concurrent writes.  
- ✅ **No hotspotting** because data fan-out is high.  

### Silver
- One hourly roll-up per hour → each partition becomes cold after processing.  
- ✅ **Low concurrency per prefix.**  

### Gold
- Uses **dynamic partition overwrite** → rewrites one partition `(dt, asset_id)` per batch.  
- ✅ Only one writer per partition; no continuous appends.  
- ✅ **No “hot” partitions** even during frequent daily runs.  

---

## 📦 Eliminating the Small File Problem

### The Problem
Frequent micro-batch writes (5-minute intervals) produce hundreds of small files per day →  
inefficient for Athena/Presto/Spark due to metadata and open-file overhead.

### The Solution

| Layer | Strategy | Result |
|--------|-----------|--------|
| **Silver** | Hourly roll-ups | 24 Parquet files/day instead of 288 JSONs |
| **Gold** | `repartition("dt","asset_id")` + overwrite | One Parquet file per asset/day |

This ensures **large, compact files**, ideal for Athena and downstream ML pipelines.  

> 💡 **Optimal file size for Parquet** is between **128–512 MB** for Athena/Spark performance.  

---

## 🧠 “Ingestion Grain” vs “Consumption Grain”

| Concept | Meaning | Optimization Focus |
|----------|----------|--------------------|
| **Ingestion Grain (Silver)** | Mirrors how data arrives and is processed | Backfills, reprocessing, schema evolution |
| **Consumption Grain (Gold)** | Mirrors how data is queried or modeled | Query speed, scan efficiency, ML training |

### Silver = Operational Convenience
Designed for engineers to debug, validate, and reprocess hourly or event-level data.

### Gold = Analytical Convenience
Designed for analysts and ML pipelines that query by date and asset, not by minute or hour.

This separation **decouples producers (ingestion jobs)** from **consumers (Athena, QuickSight, ML)**, ensuring scalability and clear responsibility per layer.

---

## 🧱 Why This Is a Real-World Standard

This approach mirrors **modern lakehouse and medallion best practices** used by companies such as **Databricks, AWS, and Snowflake**:

- **Layered design:** Each stage refined for its consumer.  
- **Partition alignment:** Ingestion grain upstream, consumption grain downstream.  
- **Controlled overwrite:** Dynamic partitioning prevents unnecessary rewrites.  
- **Compact storage:** Optimized Parquet layout avoids small files and hot partitions.  

---

## ✅ Summary

- **Bronze:** Fine-grained partitions for ingestion and replay (`id/year/month/day/hour`).  
- **Silver:** Hourly curated partitions for moderate optimization (`y/m/d/h`).  
- **Gold:** Daily analytical partitions for fast consumption (`dt/asset_id`).  
- **Different partitioning per layer is both intentional and beneficial.**  
- **Hot partitions avoided**, **small files eliminated**, and **Athena/ML optimized.**  

> This is a **common, recommended, and production-grade practice** in modern data engineering and lakehouse architectures.
