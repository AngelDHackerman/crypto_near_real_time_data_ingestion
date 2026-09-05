# =============================================================================
# Orchestration module -- Step Functions + its daily trigger  (roadmap.md,
# Phase 3; rebuilt in Phase 6)
#
# One state machine chains the Silver jobs and then the three Gold jobs.
#
# WHAT PHASE 6 REMOVED. The machine used to end with StartCrawler -> Wait 180s
# -> GetCrawler -> Choice, a hand-rolled polling loop that existed only because
# the Silver table was built by a crawler. Silver is partition-projected now
# (modules/catalog/main.tf), so the table is queryable the moment Spark writes a
# partition. Four states, ~3 minutes per run and one crawler's cost, all gone --
# and with them a `Default` branch that sent any unexpected crawler state back
# to Wait, i.e. looped forever on a FAILED crawl.
#
# WHAT PHASE 6 ADDED, AND WHY IT IS SHAPED THIS WAY. There was no `Catch`
# anywhere: retries were `States.ALL x 3` and nothing else, so a failure killed
# the execution and the EventBridge rule in modules/observability/ sent an email
# that could not say WHICH step died. Every task now catches to a single
# NotifyFailure state.
#
# The trick that makes one shared NotifyFailure able to name the failed step is
# the ResultPath on each Catch: each writes into `$.failure.<ThatStateName>`.
# The alert then serialises `$.failure`, and the object's only key IS the state
# that failed. The obvious alternatives are worse -- `$$.State.Name` inside
# NotifyFailure evaluates to "NotifyFailure", and a per-task Pass state to
# stamp the name would add five states to save one line.
#
# NotifyFailure is followed by a `Fail` state, deliberately. The execution must
# still end FAILED so the EventBridge rule keeps firing as a BACKSTOP: a Catch
# cannot see an execution a human ABORTED, a machine-level TIMED_OUT, or a
# failure of the SNS publish itself. The price is two emails on an ordinary
# failure -- one detailed, one generic. That is the right way round: a duplicate
# alert costs a delete, a missing one costs the incident. Phase 11 owns tidying
# it when it splits the topic.
#
# The Glue job names arrive as inputs from module.processing rather than from
# tfvars: the resource that creates a name is the only thing allowed to own it
# (Phase 2.1's rule, applied beyond buckets). The SNS topic ARN arrives the same
# way, from module.observability.
# =============================================================================

# -----------------------------------------------------------------------------
# The daily Gold pipeline state machine
# -----------------------------------------------------------------------------
locals {
  # Retry policy shared by every Glue task. It was already identical on all of
  # them and copied five times; written once, it is now one thing to change.
  #
  # Retry and Catch are not alternatives, they compose: Step Functions exhausts
  # the retries first and only then hands the error to the Catch. So this is
  # "three attempts at 10s, 20s, 40s" and the alert only fires after all three.
  glue_retry = [{
    ErrorEquals     = ["States.ALL"]
    IntervalSeconds = 10
    BackoffRate     = 2.0
    MaxAttempts     = 3
  }]

  # A Glue job step, built once so the five below cannot drift apart.
  #
  # ResultPath = null discards the Glue task's output and passes the state's
  # INPUT through unchanged. That is load-bearing, not tidiness: without it each
  # task would replace the whole state document with its own JobRun result, and
  # the `$.failure.<state>` an earlier Catch wrote would be gone by the time
  # NotifyFailure looked for it.
  glue_step = {
    for step in [
      { name = "SilverCmcJob", job = var.silver_job_name, next = "SilverBinanceJob" },
      { name = "SilverBinanceJob", job = var.silver_binance_job_name, next = "GoldFeaturesBaseJob" },
      { name = "GoldFeaturesBaseJob", job = var.gold_features_job_name, next = "GoldOHLCJob" },
      { name = "GoldOHLCJob", job = var.gold_ohlc_job_name, next = "GoldMLTrainingJob" },
      { name = "GoldMLTrainingJob", job = var.gold_ml_job_name, next = "Success" },
      ] : step.name => {
      Type       = "Task"
      Resource   = "arn:aws:states:::glue:startJobRun.sync"
      Parameters = { JobName = step.job }
      Retry      = local.glue_retry
      ResultPath = null
      Catch = [{
        ErrorEquals = ["States.ALL"]
        # The state's own name, used as a KEY. This is what lets one shared
        # NotifyFailure report which step died.
        ResultPath = "$.failure.${step.name}"
        Next       = "NotifyFailure"
      }]
      Next = step.next
    }
  }

  sfn_definition = jsonencode({
    Comment = "Daily crypto pipeline: Silver (CMC + Binance stream) -> Gold features -> Gold OHLC -> Gold ML"
    StartAt = "SilverCmcJob"
    States = merge(local.glue_step, {

      # SilverBinanceJob sits in the chain rather than beside it, even though no
      # Gold job reads its output yet. Two reasons: Phase 7's feature work reads
      # exactly this table, so the dependency is arriving, and a failure in a
      # Silver job should stop the run and alert rather than let Gold quietly
      # build on a layer that did not refresh. Phase 7 revisits the cadence of
      # this machine anyway -- a daily trigger over a live stream is the open
      # question it inherits.

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          # SNS subjects are capped at 100 ASCII characters and may not contain
          # newlines, so the detail goes in the body, not here.
          Subject = "Crypto daily pipeline FAILED"
          # The single key of the serialised object is the failed state's name.
          #
          # ONE LINE, NO NEWLINES IN THE FORMAT STRING. States.Format's literal
          # is parsed by Step Functions out of this JSON string, and its
          # grammar only documents escapes for quote, brace and backslash --
          # what it does with a raw newline is unspecified. An unspecified
          # thing in the ALERT path is the wrong place to find out, so the
          # message is readable on one line instead of pretty on four.
          "Message.$" = "States.Format('The daily crypto pipeline FAILED. Execution: {} on state machine {}. Failed step and error follow as JSON, where the key names the step: {}', $$.Execution.Name, $$.StateMachine.Name, States.JsonToString($.failure))"
        }
        ResultPath = null
        # If SNS itself is the thing that is broken, do not lose the failure on
        # top of it: fall through to the Fail state so the execution still ends
        # FAILED and the EventBridge backstop still fires.
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.failure.NotifyFailure"
          Next        = "PipelineFailed"
        }]
        Next = "PipelineFailed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "A step of the daily crypto pipeline failed. See the SNS alert, or $.failure in the execution history, for which one."
      }

      Success = { Type = "Succeed" }
    })
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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  glue_arn_prefix = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}"
}

# This role used to grant every Glue action on Resource = ["*"], which
# contradicted the project's own least-privilege ground rule: it could start,
# inspect and stop ANY Glue job or crawler in an account that is shared with
# other projects. Scoped to the four jobs and the one crawler this machine
# actually orchestrates.
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
    resources = [
      "${local.glue_arn_prefix}:job/${var.silver_job_name}",
      "${local.glue_arn_prefix}:job/${var.silver_binance_job_name}",
      "${local.glue_arn_prefix}:job/${var.gold_features_job_name}",
      "${local.glue_arn_prefix}:job/${var.gold_ohlc_job_name}",
      "${local.glue_arn_prefix}:job/${var.gold_ml_job_name}",
    ]
  }

  # Phase 6 deleted the "Crawler" statement -- glue:StartCrawler and
  # glue:GetCrawler on the one crawler ARN -- along with the crawler itself.

  # NotifyFailure publishes here. Note what is NOT needed alongside it: a
  # matching statement on the topic's own resource policy.
  #
  # That policy allows only events.amazonaws.com, and the header of
  # modules/observability/main.tf records that a CloudWatch alarm publishing to
  # this topic would fail SILENTLY because of it. Both are true, and they are
  # not in tension. A CloudWatch alarm publishes as a SERVICE principal, which
  # has no identity policy, so the resource policy is the only thing that can
  # allow it. Step Functions publishes as THIS ROLE, and for a principal in the
  # same account as the resource an allow in the identity policy is sufficient
  # on its own. So Phase 6 does not need to touch a policy Phase 11 is about to
  # rewrite.
  statement {
    sid       = "PublishPipelineFailureAlert"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  # Resource = "*" justified, and it is the only one left in this role.
  #
  # Step Functions writes through the CloudWatch Logs *vended logs* delivery
  # API, and AWS's own documented policy for it requires "*": logs:PutResourcePolicy
  # and the CreateLogDelivery/UpdateLogDelivery family do not accept a resource
  # ARN at all, because the delivery object does not exist yet when permission
  # is evaluated. Narrowing this to the sfn_logs log group makes the state
  # machine fail to start with an opaque logging error.
  #
  # This statement absorbed a separate "Logs" statement that granted
  # CreateLogGroup / CreateLogStream / PutLogEvents on "*" -- a strict subset of
  # what is already below, so it was pure duplication.
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
    resources = ["*"]
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

  # Was "terraform-20251011222021689700000001". See the note in
  # modules/ingestion/main.tf -- pinned for the Phase 1 import, readable now.
  target_id = "daily-gold-pipeline"

  # An empty object, not the EventBridge scheduled-event envelope. Phase 6 made
  # the state document meaningful: every Catch writes `$.failure.<state>` into
  # it and NotifyFailure reads it back, which requires the input to be a JSON
  # OBJECT. The default envelope is one, so this is belt and braces rather than
  # a fix -- but it also means the execution history shows the pipeline's own
  # state instead of thirty lines of EventBridge metadata nothing reads.
  input = jsonencode({})
}

