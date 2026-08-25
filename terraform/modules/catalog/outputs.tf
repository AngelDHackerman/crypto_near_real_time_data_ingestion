output "silver_database_name" {
  description = "Glue catalog database holding the Silver tables."
  value       = aws_glue_catalog_database.silver_db.name
}

output "gold_database_name" {
  description = "Glue catalog database holding the Gold tables and views."
  value       = aws_glue_catalog_database.gold_db.name
}

output "silver_crawler_name" {
  description = "Name of the Silver crawler. The state machine starts it by name; Phase 6 deletes it once Silver moves to partition projection."
  value       = aws_glue_crawler.silver_crawler.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup enforcing the shared result location and SSE."
  value       = aws_athena_workgroup.workgroup.name
}
