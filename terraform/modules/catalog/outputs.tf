output "silver_database_name" {
  description = "Glue catalog database holding the Silver tables."
  value       = aws_glue_catalog_database.silver_db.name
}

output "gold_database_name" {
  description = "Glue catalog database holding the Gold tables and views."
  value       = aws_glue_catalog_database.gold_db.name
}

# Phase 6 deleted `silver_crawler_name`. Nothing starts a crawler any more: the
# Silver tables below are partition-projected, so they are queryable the moment
# Spark writes a partition.

output "silver_table_names" {
  description = "The three partition-projected Silver tables, in the order Bronze produces them: CoinMarketCap, then the two Binance stream datasets."
  value = [
    aws_glue_catalog_table.silver_cmc.name,
    aws_glue_catalog_table.silver_binance_trades.name,
    aws_glue_catalog_table.silver_binance_klines.name,
  ]
}

output "athena_workgroup_name" {
  description = "Athena workgroup enforcing the shared result location and SSE."
  value       = aws_athena_workgroup.workgroup.name
}
