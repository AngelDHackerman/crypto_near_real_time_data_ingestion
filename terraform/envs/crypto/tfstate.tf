# =============================================================================
# Terraform state bucket  (roadmap.md, Phase 2)
#
# This bucket holds the state of THIS config -- including its own entry. That
# is intentional and safe: S3 versioning means an apply that damages the state
# leaves every previous version recoverable.
#
# Why a dedicated bucket rather than reusing `artifacts`:
#   1. The artifacts lifecycle rule expires noncurrent versions after 90 days,
#      bucket-wide. Version history is the only thing that saves a corrupted
#      apply -- putting state there would put a 90-day fuse on the whole
#      recovery path.
#   2. The Silver Glue role holds s3:PutObject/s3:DeleteObject on artifacts/*
#      with no prefix restriction. A data-processing role must not be able to
#      delete the Terraform state.
#   3. Athena writes query results there. Four unrelated jobs, one blast radius.
#
# THE STANDING RULE: no runtime role -- Lambda, Glue, Step Functions, Athena,
# crawler -- ever gets an IAM statement naming this bucket. Only a human
# operator's credentials read or write it. If a future phase needs CI to run
# Terraform, that gets its own role, and it is the ONLY exception.
#
# Deliberately NO lifecycle_configuration: unlike every other bucket here,
# nothing in this one should ever expire. Old state versions are the undo
# history, and 100 KB of JSON per version costs nothing.
#
# This bucket was created by terraform/bootstrap-tfstate/ (local state) and then
# imported here, resolving the chicken-and-egg. That directory was deleted once
# the import landed -- two configs declaring the same bucket is a footgun. To
# rebuild from nothing, recreate it from the Phase 2 notes in roadmap.md.
#
# WHY THIS IS NOT IN modules/storage/  (roadmap.md, Phase 3)
# That module is the LAKE. This bucket is infrastructure *of* the
# infrastructure, and it belongs next to backend.tf, which is the only other
# file that names it. Keeping it out of the module also means a second
# environment cannot instantiate module.storage and silently acquire a second
# state bucket along with its four lake buckets.
# =============================================================================

# Same shape as the tags in modules/storage/, deliberately duplicated rather
# than shared: this bucket is not a lake layer, and a module output is not worth
# creating just to carry three static strings across a boundary.
locals {
  bucket_tags = {
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "crypto-tf-state-${var.aws_account_id}"

  tags = merge(local.bucket_tags, {
    Name  = "crypto-tf-state-${var.aws_account_id}"
    Layer = "tfstate"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
