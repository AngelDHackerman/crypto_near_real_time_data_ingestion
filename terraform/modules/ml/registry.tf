# =============================================================================
# Model registry  (roadmap.md, Phase 9)
#
# The package GROUP is Terraform's; the VERSIONS inside it are not, and that
# boundary is the same one Phase 8 drew around the training job. A group is
# durable infrastructure with a desired state. A version is the record of one
# training run -- an event that happened. Managing versions in Terraform would
# mean an apply either recreates them or, worse, destroys the ones it did not
# create, which for a model registry means deleting the provenance of whatever
# is currently serving traffic.
#
# ml/registry/register_model.py creates versions; ml/registry/promote_model.py
# changes their approval state, using criteria that live in promotion_policy.py
# and have tests. See the header of that file for why "scripted, not clicked"
# means the CRITERIA are code rather than the API call.
#
# Free: a model package group costs nothing, and so do the versions in it.
# =============================================================================

resource "aws_sagemaker_model_package_group" "signal_model" {
  model_package_group_name        = "${var.project}-signal-${var.environment}"
  model_package_group_description = "XGBoost binary signal model: does the 60m forward return clear a round-trip taker fee. Versions are registered by ml/registry/register_model.py and promoted by promote_model.py."

  tags = var.tags
}

# -----------------------------------------------------------------------------
# The promotion permissions, as a standalone policy
#
# Attached to nothing today, on purpose. Promotion is run by a human now and by
# Phase 12's GitHub Actions role later; creating the ROLE here would mean
# guessing Phase 12's trust policy (OIDC provider, repository, branch
# conditions) months before it is written, and a role with a wrong trust policy
# is worse than no role.
#
# The policy itself is not a guess -- these are exactly the calls the two
# scripts make -- so it is written now, reviewed now, and attached in one line
# when the role exists. An unattached IAM policy grants nothing and costs
# nothing.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "model_promotion" {
  statement {
    sid = "RegisterAndPromoteVersions"
    actions = [
      "sagemaker:CreateModelPackage",
      "sagemaker:UpdateModelPackage",
      "sagemaker:DescribeModelPackage",
      "sagemaker:ListModelPackages",
    ]
    resources = [
      aws_sagemaker_model_package_group.signal_model.arn,
      "${aws_sagemaker_model_package_group.signal_model.arn}/*",
    ]
  }

  # Scoped to the group's own name via a condition, because DescribeTrainingJob
  # takes a training job ARN and the job names are generated at run time. The
  # tag is stamped by launch_training.py.
  statement {
    sid       = "ReadTheTrainingJobBeingRegistered"
    actions   = ["sagemaker:DescribeTrainingJob"]
    resources = ["arn:aws:sagemaker:*:*:training-job/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["near-real-time-crypto"]
    }
  }

  statement {
    sid       = "ReadTheMetricsFileBeingRegistered"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/${var.ml_model_prefix}/*"]
  }
}

resource "aws_iam_policy" "model_promotion" {
  name        = "${var.project}-model-promotion-${var.environment}"
  description = "Register and promote model package versions. Attached to Phase 12's CI role when that role exists; unattached policies grant nothing."
  policy      = data.aws_iam_policy_document.model_promotion.json
  tags        = var.tags
}
