terraform {
  # Pinned exactly. A floating constraint (">= 5.0") lets `terraform init`
  # pull provider v6, whose breaking changes in the S3 resources would show up
  # as false drift in the import plan.
  required_version = "~> 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Fail fast if credentials point at the wrong account.
  allowed_account_ids = [var.aws_account_id]

  # NOTE: `default_tags` is deliberately NOT set here. Adding it before the
  # import would apply new tags to every already-deployed resource and flood
  # the import plan with diffs. It is introduced in Phase 3 (refactor), as a
  # deliberate change reviewed on its own plan.
}

data "aws_caller_identity" "current" {}
