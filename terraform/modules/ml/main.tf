# =============================================================================
# ML module -- the durable half of the model lifecycle  (roadmap.md, Phase 8)
#
# WHAT IS HERE AND WHAT IS DELIBERATELY NOT. Terraform owns the things that have
# a desired state: the execution role, the repository, the output locations.
# It does NOT own the training job, because a training job is an EXECUTION --
# it starts, produces an artifact and ends. "This job has run" is not a state
# you converge on, and modelling it as one would mean an apply either recreates
# it forever or never again. ml/training/launch_training.py owns that half.
#
# The same boundary Phase 7 drew around the backfill, and the same one Phase 12's
# pipeline will call across.
#
# ============================================================================
# THE NO-VPC DECISION, WRITTEN DOWN RATHER THAN LEFT AS AN OMISSION
# ============================================================================
#
# There is no VpcConfig on the training job, and that is a choice with a number
# attached. Putting a SageMaker training job inside a VPC costs one of:
#
#   NAT Gateway               ~$32/month + $0.045/GB processed
#   4 interface endpoints     ~$7/month each = ~$28/month
#                             (ecr.api, ecr.dkr, logs, sts -- and s3 as a free
#                             gateway endpoint, which is the only cheap one)
#
# Either way it is roughly the cost of the ENTIRE awake project, spent so that
# a job which reads one S3 prefix and writes another can do so without touching
# a public endpoint.
#
# What a VPC would actually buy here: nothing this workload needs. There is no
# private data source to reach, no on-premises system, no compliance boundary,
# and the job's only network calls are to S3, ECR and CloudWatch -- all of them
# AWS services reached over AWS's network with SigV4 auth either way. Data
# never traverses the public internet in the sense people mean when they ask
# for a VPC; it traverses AWS's backbone with or without one.
#
# Where a VPC WOULD have a real argument is Phase 10, serving: a private
# inference endpoint that only the VPC can reach is a genuine security posture,
# not a ritual. That is why the roadmap puts the VPC question there and answers
# it "no" here.
#
# Knowing when NOT to reach for a VPC is the same skill as knowing how to build
# one, and this project already built one -- Phase 5's producer VPC, also
# deliberately without a NAT Gateway. The pattern is consistent: pay for network
# isolation where it protects something, not where it decorates a diagram.
# =============================================================================

data "aws_iam_policy_document" "sagemaker_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_execution" {
  name               = "${var.project}-sagemaker-execution-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_trust.json
  tags               = var.tags
}

# Least privilege, scoped by ARN and by PREFIX. The role can read exactly one
# dataset and write exactly one output location -- notably it cannot read
# Bronze or Silver, cannot write anywhere in the lake, and has no access at all
# to the Terraform state bucket (the standing rule since Phase 2).
data "aws_iam_policy_document" "sagemaker_execution" {
  statement {
    sid     = "S3ListScopedToWhatItReads"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      var.gold_bucket_arn,
      var.artifacts_bucket_arn,
    ]
    # ListBucket is a BUCKET-level action, so it cannot be scoped by a resource
    # ARN alone -- the prefix has to be a condition or the grant silently
    # becomes "list the whole bucket".
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${var.gold_ml_prefix}/*",
        "${var.ml_code_prefix}/*",
        "${var.ml_model_prefix}/*",
        "", "/",
      ]
    }
  }

  statement {
    sid       = "S3ReadTrainingData"
    actions   = ["s3:GetObject"]
    resources = ["${var.gold_bucket_arn}/${var.gold_ml_prefix}/*"]
  }

  statement {
    sid       = "S3ReadTrainingCode"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/${var.ml_code_prefix}/*"]
  }

  statement {
    sid = "S3WriteModelArtifacts"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${var.artifacts_bucket_arn}/${var.ml_model_prefix}/*"]
  }

  # Phase 11: the endpoint captures every request and response here. It is
  # Phase 13's prediction log, kept by the platform rather than built -- and it
  # is granted to the SAME role because a SageMaker endpoint writes captures as
  # its execution role. PutObject only: capture is append-only by nature, and a
  # grant to delete a prediction record is a grant to edit history.
  statement {
    sid       = "S3WriteDataCapture"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${var.artifacts_bucket_arn}/${var.ml_capture_prefix}/*"]
  }

  # No s3:DeleteObject anywhere. A training job has no reason to remove an
  # artifact, and the bucket's versioning plus lifecycle handles expiry -- so
  # the permission would exist only for an accident or an incident.

  # Resource = "*" justified: SageMaker creates log groups and streams under
  # /aws/sagemaker/TrainingJobs at runtime, with names not known at plan time.
  # Same justification the Glue roles carry.
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }

  # Resource = "*" justified: cloudwatch:PutMetricData does not accept a
  # resource ARN at all -- the API is scoped by namespace condition, not by
  # resource. Narrowed by namespace instead, which is the only lever it has.
  statement {
    sid       = "PublishTrainingMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/TrainingJobs", "aws/sagemaker/TrainingJobs"]
    }
  }

  # For Phase 12, when training moves to an image this project builds. Phase 8
  # trains on AWS's managed XGBoost container, which SageMaker pulls on the
  # service's own behalf and not with this role -- so today these grants are
  # unused. They are here because the repository below is, and a repository
  # nothing can pull from is a Phase 12 debugging session waiting to happen.
  statement {
    sid = "ECRPullTrainingImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.model_training.arn]
  }

  # Resource = "*" justified: ecr:GetAuthorizationToken is an account-level API
  # that does not accept a resource ARN. It grants a token, not access to any
  # image -- the statement above is what decides which images can be pulled.
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "sagemaker_execution" {
  name   = "${var.project}-sagemaker-execution-policy-${var.environment}"
  policy = data.aws_iam_policy_document.sagemaker_execution.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_execution" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = aws_iam_policy.sagemaker_execution.arn
}

# -----------------------------------------------------------------------------
# ECR -- the training image's home, for Phase 12
#
# Empty today, and NOTHING REFERENCES IT. That distinction is the whole reason
# it is safe to create here. Phase 5 built an ECR repository AND a task
# definition that pulls `:latest` from it, then never built the image -- which
# turned an empty repository into the one precondition standing between the
# wake-up flags and a working wake-up. An empty repository is free and harmless;
# an empty repository that something points at is a time bomb.
#
# So Phase 8 trains on AWS's managed XGBoost container (pinned to 1.7-1 in
# launch_training.py) and this sits unused until Phase 12's pipeline builds and
# pushes in the same run. Nothing can break in the meantime because nothing is
# looking.
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "model_training" {
  name = "${var.project}-model-training-${var.environment}"

  # IMMUTABLE, and this is the "explicit image tagging scheme" the DoD asks for.
  # A mutable tag means the image behind `v1.4.2` can be replaced, so a model
  # artifact's recorded provenance stops being a fact about which code produced
  # it. That is the same discipline this project applies to Terraform provider
  # versions, applied to images: pin exactly, never float.
  #
  # The scheme: <semver>-<git short sha>, e.g. 1.4.2-a3f91c0. The semver is the
  # human-meaningful version and the sha makes it unambiguous even if someone
  # tags twice. `latest` is deliberately never used -- it is what makes Phase 5's
  # task definition unable to say what it would actually run.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "model_training" {
  repository = aws_ecr_repository.model_training.name

  # ECR storage is $0.10/GB-month and a training image is not small. Keeping
  # ten is enough to roll back through a few releases; keeping all of them is a
  # bill that grows with the commit count.
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
