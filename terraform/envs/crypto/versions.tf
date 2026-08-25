terraform {
  # Pinned exactly. A floating constraint (">= 5.0") lets `terraform init`
  # pull provider v6, whose breaking changes in the S3 resources would show up
  # as false drift in the plan.
  #
  # Every module under ../../modules/ repeats these pins in its own versions.tf:
  # Terraform does not inherit required_providers into child modules, so without
  # them a module is free to resolve a different provider version than this env.
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
