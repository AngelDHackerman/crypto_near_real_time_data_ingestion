variable "aws_account_id" {
  description = "AWS account ID. Suffixes every bucket name -- S3 names are globally unique across all AWS accounts, so this is what makes the name ours by construction."
  type        = string
}

variable "environment" {
  description = "Environment name. Tag only; it is NOT part of the bucket names, which are already account-scoped."
  type        = string
}

variable "athena_results_prefix" {
  description = "Prefix inside the artifacts bucket where Athena writes query results. Scopes the 30-day expiry rule to regenerable output only."
  type        = string
}
