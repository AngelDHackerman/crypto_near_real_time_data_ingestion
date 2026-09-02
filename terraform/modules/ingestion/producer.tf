# =============================================================================
# The Binance WebSocket producer -- ECR + ECS/Fargate  (roadmap.md, Phase 5)
#
# A WebSocket needs a process that stays alive. Lambda's 15-minute ceiling rules
# it out, so this is the first thing in the project that runs continuously, and
# the first recurring bill. The decision and its costs are written up in Phase 5
# of roadmap.md; the short version is 0.25 vCPU / 0.5 GB at ~$12.66/month when
# it is switched on, and $0 while it is not.
#
# WHAT IS GATED AND WHAT IS NOT. Nearly all of this file is free to exist, so it
# is applied for real while the project is dormant: the ECR repository, the task
# definition, both IAM roles, the log group, the cluster. Only the service's
# desired_count is gated -- a Fargate service with no tasks costs nothing, so
# unlike the Kinesis stream it does not have to be deleted to be free.
#
# THE PRODUCER SHIPS AS AN IMAGE, NOT A ZIP TO THE ARTIFACTS BUCKET. Phase 2.1's
# storage rule sends build artifacts to crypto-artifacts-<acct>/, and the Glue
# scripts still obey it. A Fargate task pulls an image; it cannot download a zip
# from S3 and run it. Shipping both would put one fact in two places, which is
# the failure that rule exists to prevent. The deviation is deliberate and is
# recorded in the roadmap rather than left for a reader to notice.
# =============================================================================

# -----------------------------------------------------------------------------
# ECR -- where the producer image lives
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "producer" {
  name                 = "crypto-binance-producer-${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "crypto-binance-producer-${var.environment}"
  }
}

# Storage is $0.10/GB-month and the free tier covers 500 MB. A producer image is
# ~120 MB, so three of them fit free and this policy keeps it that way -- an
# untended repository grows one layer set per push, forever.
resource "aws_ecr_lifecycle_policy" "producer" {
  repository = aws_ecr_repository.producer.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 3 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# ECS -- cluster, task definition, service
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "producer" {
  name = "crypto-producer-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = "crypto-producer-${var.environment}"
  }
}

resource "aws_cloudwatch_log_group" "producer" {
  name              = "/ecs/crypto-binance-producer-${var.environment}"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "producer" {
  family                   = "crypto-binance-producer-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.producer_cpu
  memory                   = var.producer_memory

  execution_role_arn = aws_iam_role.producer_execution.arn
  task_role_arn      = aws_iam_role.producer_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "producer"
    image     = "${aws_ecr_repository.producer.repository_url}:${var.producer_image_tag}"
    essential = true

    environment = [
      { name = "KINESIS_STREAM_NAME", value = local.kinesis_stream_name },
      { name = "AWS_REGION", value = var.aws_region },
      # The subscription list is passed IN, not baked into the image: Terraform
      # reads config/tracked_assets.json and so do the Lambda and the Gold job,
      # which is what stops the three of them drifting apart. Rebuilding the
      # image to change one symbol would break that.
      { name = "BINANCE_SYMBOLS", value = join(",", var.streamed_symbols) },
      { name = "BINANCE_STREAMS", value = join(",", var.binance_stream_types) },
      { name = "BATCH_MAX_BYTES", value = tostring(var.producer_batch_max_bytes) },
      { name = "BATCH_MAX_SECONDS", value = tostring(var.producer_batch_max_seconds) },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.producer.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "producer"
      }
    }
  }])

  tags = {
    Name = "crypto-binance-producer-${var.environment}"
  }
}

resource "aws_ecs_service" "producer" {
  name            = "crypto-binance-producer-${var.environment}"
  cluster         = aws_ecs_cluster.producer.id
  task_definition = aws_ecs_task_definition.producer.arn
  launch_type     = "FARGATE"

  # The gate. Zero tasks, zero vCPU-hours, zero public IPs, zero dollars.
  desired_count = var.streaming_enabled ? var.producer_desired_count : 0

  # A SINGLETON, DELIBERATELY. The defaults (100 / 200) would start a second
  # task before draining the first, and for a few seconds two producers would
  # hold two WebSockets and write every tick to Kinesis twice. Duplicates are
  # far worse than a gap here: a gap is visible in the data, a duplicate looks
  # like real volume. 0 / 100 means stop-then-start, accepting a short
  # interruption on every deploy in exchange for exactly-one-writer.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets         = var.public_subnet_ids
    security_groups = [var.producer_security_group_id]

    # Public IP instead of a NAT Gateway: ~$3.65/month against ~$33/month, for a
    # task nothing can reach inbound anyway. See modules/network/main.tf.
    assign_public_ip = true
  }

  tags = {
    Name = "crypto-binance-producer-${var.environment}"
  }
}

# -----------------------------------------------------------------------------
# IAM -- two roles, because they are two different jobs
#
# The EXECUTION role belongs to the ECS agent: pull the image, write the log
# stream. It acts before the container starts. The TASK role belongs to the
# process inside the container: write to Kinesis, and nothing else. Collapsing
# them into one role is the common shortcut and it hands the application ECR
# pull rights it has no use for.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "producer_execution" {
  name = "ecs-producer-execution-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "producer_execution" {
  role       = aws_iam_role.producer_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "producer_task" {
  name = "ecs-producer-task-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

# Scoped to the one stream ARN, never "*".
#
# The ARN is COMPOSED here rather than read from aws_kinesis_stream.binance_ticks
# on purpose: that resource has count = 0 while the project is dormant, so
# referencing it would make this policy -- which is free and should exist --
# depend on a resource that deliberately does not. The name is owned by
# local.kinesis_stream_name, which the stream itself also uses, so the two
# cannot drift.
data "aws_iam_policy_document" "producer_task" {
  statement {
    sid = "WriteBinanceTicksToKinesis"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
      "kinesis:DescribeStreamSummary",
    ]
    resources = [local.kinesis_stream_arn]
  }
}

resource "aws_iam_role_policy" "producer_task" {
  name   = "ecs-producer-kinesis-write-${var.environment}"
  role   = aws_iam_role.producer_task.id
  policy = data.aws_iam_policy_document.producer_task.json
}
