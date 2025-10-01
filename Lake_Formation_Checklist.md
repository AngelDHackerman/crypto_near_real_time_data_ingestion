# ✅ Lake Formation Checklist – Crypto Project (Silver & Gold)

This checklist is reusable for both **Silver** and **Gold** layers of the crypto project.

---

## 1. Register the S3 Location in Lake Formation
- Go to **Lake Formation → Data locations → Register location**.  
- Example path for Silver:  
  ```
  s3://lake-curated-data-silver-gold-crypto/top10/silver
  ```  
  (for Gold use `.../gold`).  
- Choose IAM role: `AWSServiceRoleForLakeFormationDataAccess`.  
- Permission mode: **Hybrid access mode**.  
- Save.

---

## 2. Review Location Permissions
- In **Data locations**, confirm the new path is registered.  
- Required principals:  
  - `near-real-time-crypto-glue-crawler-role` (IAM role for the crawler).  
  - `angel-adming` (IAM user for testing).  
- Both should have **Data location access**.  
- The IAM user should also have *grantable* permissions if delegation is required.

---

## 3. Grant Database Permissions
- Go to **Lake Formation → Data permissions → Grant**.  
- Principals:  
  - `near-real-time-crypto-glue-crawler-role`  
  - `angel-adming`  
- Catalog: default (`913524903233`).  
- Database:  
  - `crypto_silver_db` (for Silver)  
  - `crypto_gold_db` (for Gold).  
- Select the following permissions:  
  - **Create table**  
  - **Alter**  
  - **Describe**  
- Also grant the same in *Grantable permissions*.

---

## 4. Run the Crawler
- Go to **Glue → Crawlers**.  
- Select the crawler (`near-real-time-crypto-silver-crawler-crypto` or the Gold crawler).  
- Run → wait until state is `Succeeded`.  
- Verify that new tables appear in the selected database.

---

## 5. Test with Athena
- Open **Athena → Query Editor**.  
- Select the corresponding database (`crypto_silver_db` or `crypto_gold_db`).  
- Run a simple query:  
  ```sql
  SELECT * 
  FROM silver_table_name
  LIMIT 10;
  ```  
- Ensure Parquet files are readable without **AccessDeniedException** errors.

---

## 6. Repeat for Gold
- When the Gold layer is ready, repeat **steps 1–5** with the Gold S3 path and database.  
- The checklist is identical.

---

## 📌 Troubleshooting Tips
If you encounter **AccessDeniedException** in Athena:  
- Ensure the **S3 path** is registered in Lake Formation.  
- Verify the **crawler role** has permissions on both *Data locations* and *Database*.  
- Confirm **Hybrid access mode** is enabled (avoids conflicts with IAM permissions).

