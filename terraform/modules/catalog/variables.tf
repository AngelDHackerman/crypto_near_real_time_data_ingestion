variable "project" {
  description = "Project name. Prefixes the crawler, its role and the Athena workgroup."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "tags" {
  description = "Common tags applied to the catalog resources."
  type        = map(string)
}

variable "silver_bucket_id" {
  description = "Name of the silver bucket the crawler scans. Comes from module.storage."
  type        = string
}

variable "silver_bucket_arn" {
  description = "ARN of the silver bucket, used to scope the crawler's read policy."
  type        = string
}

variable "silver_prefix" {
  description = "Top-level prefix inside the silver bucket -- the SOURCE, not the layer."
  type        = string
}

variable "artifacts_bucket_id" {
  description = "Name of the artifacts bucket where Athena writes query results."
  type        = string
}

variable "athena_results_prefix" {
  description = "Prefix inside the artifacts bucket for Athena query results."
  type        = string
}
