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
