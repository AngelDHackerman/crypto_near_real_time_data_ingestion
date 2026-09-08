terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    # serving.tf packages the DuckDB layer and the inference Lambda with
    # data.archive_file. Declared here for the same reason as in
    # modules/ingestion: a child module does not inherit the root's providers.
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
    }
  }
}
