terraform {
  required_version = "~> 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    # slack.tf builds the notifier zip with data.archive_file. Terraform does
    # NOT inherit required_providers into child modules, so without this entry
    # the provider is only INFERRED from the resource type prefix -- it resolves,
    # but unpinned, which is the thing Phase 3 wrote this rule to prevent.
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
    }
  }
}
