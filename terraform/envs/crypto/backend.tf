# =============================================================================
# Remote state backend  (roadmap.md, Phase 2)
#
# Values here are hardcoded on purpose: backend blocks are read before
# variables exist, so `var.aws_account_id` is not available in this file. It is
# the one place in the config where a literal account id is correct.
#
# use_lockfile = true is native S3 locking (Terraform >= 1.10): the lock is a
# conditional-write `.tflock` object next to the state. No DynamoDB table to
# provision, pay for, or forget about.
#
# encrypt = true is belt-and-braces -- the bucket already has SSE by default
# (see tfstate.tf) -- but it makes a plaintext PUT fail loudly rather than
# silently depending on a bucket setting somewhere else.
#
# The state bucket is managed by this very config (tfstate.tf). To destroy this
# project for real, `terraform state rm` the tf_state resources first, then
# empty and delete the bucket by hand.
# =============================================================================

terraform {
  backend "s3" {
    bucket       = "crypto-tf-state-913524903233"
    key          = "crypto/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
