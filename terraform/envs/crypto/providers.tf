provider "aws" {
  region = var.aws_region

  # Fail fast if credentials point at the wrong account. This account is shared
  # with other projects, so "wrong account" is a real failure mode, not a
  # theoretical one.
  allowed_account_ids = [var.aws_account_id]

  # Kept out of Phase 1 on purpose: adding it before the import would have
  # applied new tags to every already-deployed resource and flooded the import
  # plan with diffs, hiding the drift that actually mattered. Introduced here in
  # Phase 3, on its own reviewed plan.
  #
  # Every tag is answerable from the account alone -- this account is shared
  # with other projects (the neighbour loteria-pipeline among them), so
  # "which project owns this?" is a question someone genuinely has to ask of a
  # bare resource listing. ManagedBy records that clicking in the console is
  # never the answer, per the project's first ground rule.
  #
  # Resource-level `tags` still win over these on conflict, so the per-resource
  # Name and Layer tags on the buckets are unaffected.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "crypto_near_real_time_data_ingestion"
    }
  }
}

data "aws_caller_identity" "current" {}
