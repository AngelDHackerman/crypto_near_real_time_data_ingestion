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



