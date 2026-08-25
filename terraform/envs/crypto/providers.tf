provider "aws" {
  region = var.aws_region

  # Fail fast if credentials point at the wrong account. This account is shared
  # with other projects, so "wrong account" is a real failure mode, not a
  # theoretical one.
  allowed_account_ids = [var.aws_account_id]

  # NOTE: `default_tags` is deliberately NOT set here. Adding it before the
  # Phase 1 import would have applied new tags to every already-deployed
  # resource and flooded the import plan with diffs. It is introduced in
  # Phase 3 as a deliberate change reviewed on its own plan.
}

data "aws_caller_identity" "current" {}
