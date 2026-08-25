# =============================================================================
# Orchestration module -- Step Functions + its daily trigger  (roadmap.md, Phase 3)
#
# One state machine chains the four Glue jobs and then refreshes the Silver
# catalog. The StartCrawler / Wait / GetCrawler / Choice polling loop at the end
# exists only because Silver still depends on a crawler; Phase 6 migrates Silver
# to partition projection and those four states go away with it.
#
# Known gap, recorded rather than fixed here: there is no `Catch` anywhere. On
# failure the execution dies and the EventBridge rule in modules/observability/
# fires SNS -- which works, but the alert cannot name the step that failed.
# Phase 6 adds the Catch and a NotifyFailure state.
#
# The Glue job and crawler names arrive as inputs from module.processing and
# module.catalog rather than from tfvars: the resource that creates a name is
# the only thing allowed to own it (Phase 2.1's rule, applied beyond buckets).
# =============================================================================

# -----------------------------------------------------------------------------
# The daily Gold pipeline state machine
# -----------------------------------------------------------------------------
locals {
  sfn_definition = jsonencode({
    Comment = "Daily Gold Pipeline for Crypto (Silver -> Gold Features -> Gold OHLC -> Gold ML -> Silver Crawler)"
    StartAt = "SilverJob"
    States = {
      SilverJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.silver_job_name }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldFeaturesBaseJob"
      }

      GoldFeaturesBaseJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.gold_features_job_name }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldOHLCJob"
      }

      GoldOHLCJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.gold_ohlc_job_name }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldMLTrainingJob"
      }

      GoldMLTrainingJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.gold_ml_job_name }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "StartCrawler"
      }

      StartCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = var.silver_crawler_name }
        Retry = [
          {
            # Retry only on specific known transient Glue/Throttle errors
            ErrorEquals     = ["ThrottlingException", "Glue.CrawlerRunningException"]
            IntervalSeconds = 15
            BackoffRate     = 2.0
            MaxAttempts     = 5
          },
          {
            # Catch-all retry must be in its own block with States.ALL alone
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 15
            BackoffRate     = 2.0
            MaxAttempts     = 3
          }
        ]
        Next = "WaitCrawler"
      }

      WaitCrawler = {
        Type    = "Wait"
        Seconds = 180
        Next    = "GetCrawler"
      }

      GetCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = { Name = var.silver_crawler_name }
        ResultSelector = {
          # State.$ creates $.State from the JSON path $.Crawler.State returned by the task
          "State.$" = "$.Crawler.State"
        }
        Next = "CrawlerDoneChoice"
      }

      CrawlerDoneChoice = {
        Type = "Choice"
        Choices = [
          # if crawler is READY -> success
          { Variable = "$.State", StringEquals = "READY", Next = "Success" },
          # if crawler still RUNNING -> poll again
          { Variable = "$.State", StringEquals = "RUNNING", Next = "WaitCrawler" }
        ]
        # default: if other unexpected state -> go to WaitCrawler (or consider Fail)
        Default = "WaitCrawler"
      }

      Success = { Type = "Succeed" }
    }
  })
}

resource "aws_sfn_state_machine" "daily_gold_pipeline" {
  name       = "near-real-time-crypto-daily-gold-pipeline"
  role_arn   = aws_iam_role.sfn_role.arn
  definition = local.sfn_definition

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
  }
}

resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/near-real-time-crypto-daily-gold-pipeline"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# IAM -- Step Functions execution role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "sfn_role" {
  name               = "sfn-orchestrator-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "sfn_policy" {
  statement {
    sid    = "GlueJobs"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Crawler"
    effect = "Allow"
    actions = [
      "glue:StartCrawler",
      "glue:GetCrawler"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogsDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"] # PutResourcePolicy exige "*"
  }
}

resource "aws_iam_policy" "sfn_policy" {
  name   = "sfn-orchestrator-crypto-policy"
  policy = data.aws_iam_policy_document.sfn_policy.json
}

resource "aws_iam_role_policy_attachment" "sfn_attach" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = aws_iam_policy.sfn_policy.arn
}

# -----------------------------------------------------------------------------
# Schedule -- EventBridge -> Step Functions
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "daily_gold_silver" {
  name                = "near-real-time-dialy-gold-silver-${var.environment}"
  schedule_expression = var.daily_schedule_cron
  description         = "Trigger daily step functions (silver -> Gold -> Crawler)"
}

# Permissions to allow EventBridge to StartExecution in SFN
data "aws_iam_policy_document" "events_to_sfn_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "events_to_sfn_role" {
  name               = "events-to-sfn-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.events_to_sfn_assume.json
}

data "aws_iam_policy_document" "events_to_sfn_policy" {
  statement {
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.daily_gold_pipeline.arn]
  }
}

resource "aws_iam_policy" "events_to_sfn_policy" {
  name   = "events-to-sfn-policy-crypto"
  policy = data.aws_iam_policy_document.events_to_sfn_policy.json
}

resource "aws_iam_role_policy_attachment" "events_to_sfn_attach" {
  role       = aws_iam_role.events_to_sfn_role.name
  policy_arn = aws_iam_policy.events_to_sfn_policy.arn
}

resource "aws_cloudwatch_event_target" "daily_gold_target" {
  rule     = aws_cloudwatch_event_rule.daily_gold_silver.name
  arn      = aws_sfn_state_machine.daily_gold_pipeline.arn
  role_arn = aws_iam_role.events_to_sfn_role.arn

  # See note in eventBridge.tf: pinned to the AWS-generated ID for the import.
  target_id = "terraform-20251011222021689700000001"
}

