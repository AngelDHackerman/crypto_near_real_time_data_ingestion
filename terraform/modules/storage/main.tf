# =============================================================================
# Storage module -- the lake, one bucket per layer  (roadmap.md, Phase 2.1 / 3)
#
# WHAT IS DELIBERATELY NOT HERE: the Terraform state bucket. It lives at the env
# level in envs/crypto/tfstate.tf, next to backend.tf. This module is the LAKE --
# bronze, silver, gold, artifacts -- and the state bucket is infrastructure *of*
# the infrastructure, not a layer of it. Bundling them would also mean that
# instantiating this module for a second environment would silently produce a
# second state bucket in the bargain.
#
# Naming convention: crypto-<purpose>-<account_id>.
# The account id suffix is not decoration: S3 bucket names are globally unique
# across every AWS account, and the bare names (crypto-tf-state, crypto-tfstate)
# are already registered by strangers. The suffix makes the name ours by
# construction.
#
# What goes where -- the standing rule for the whole project:
#   bronze / silver / gold : that layer's data, and nothing else
#   artifacts              : everything that is NOT lake data -- Glue job scripts,
#                            Lambda and producer packages, Spark tmp/ and Spark UI
#                            logs, Athena query results, and any future one-off
#   crypto-tf-state-*      : Terraform state only. No runtime role gets access.
#
# The top-level prefix inside a lake bucket is the SOURCE (cmc/, binance/), never
# the layer -- the bucket already names the layer.
#
# These buckets are the single source of truth for their own names. Nothing else
# in this codebase reconstructs a bucket name from variables; everything
# references aws_s3_bucket.<x>.id / .arn. That duplication is what made the
# Phase 1 state recovery dangerous. Consumers read them from outputs.tf.
#
# The Glue job scripts that live in the artifacts bucket are NOT declared here
# either -- an aws_s3_object is a deployment artifact of the job that runs it, so
# they sit in modules/processing/ alongside the aws_glue_job resources.
# =============================================================================

locals {
  bucket_tags = {
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

# -----------------------------------------------------------------------------
# BRONZE -- raw ingested payloads
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "bronze" {
  bucket = "crypto-bronze-layer-${var.aws_account_id}"

  tags = merge(local.bucket_tags, {
    Name  = "crypto-bronze-layer-${var.aws_account_id}"
    Layer = "bronze"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  # Bucket-level, not prefix-filtered. The old config filtered on "top10/..."
  # prefixes, which meant any prefix rename silently switched the rule off.
  rule {
    id     = "bronze-30d-to-glacier-ir"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# -----------------------------------------------------------------------------
# SILVER -- cleaned and typed tables
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "silver" {
  bucket = "crypto-silver-layer-${var.aws_account_id}"

  tags = merge(local.bucket_tags, {
    Name  = "crypto-silver-layer-${var.aws_account_id}"
    Layer = "silver"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    id     = "silver-360d-to-onezone-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 360
      storage_class = "ONEZONE_IA"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }
}

# -----------------------------------------------------------------------------
# GOLD -- feature/ML datasets. Stays in Standard: this is what gets queried.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "gold" {
  bucket = "crypto-gold-layer-${var.aws_account_id}"

  tags = merge(local.bucket_tags, {
    Name  = "crypto-gold-layer-${var.aws_account_id}"
    Layer = "gold"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "gold" {
  bucket                  = aws_s3_bucket.gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    id     = "gold-keep-standard"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# -----------------------------------------------------------------------------
# ARTIFACTS -- everything that is not lake data
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = "crypto-artifacts-${var.aws_account_id}"

  tags = merge(local.bucket_tags, {
    Name  = "crypto-artifacts-${var.aws_account_id}"
    Layer = "artifacts"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-artifact-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Query results are regenerable output, not artifacts. This prefix filter is
  # legitimate: it scopes a rule to one kind of content inside the bucket, it is
  # not standing in for a missing bucket boundary.
  rule {
    id     = "delete-athena-query-results"
    status = "Enabled"

    filter {
      prefix = "${var.athena_results_prefix}/"
    }

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Spark scratch. Glue writes here on every run and never cleans up.
  rule {
    id     = "delete-spark-scratch"
    status = "Enabled"

    filter {
      prefix = "tmp/"
    }

    expiration {
      days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
