# =============================================================================
# Observability module -- failure alerting  (roadmap.md, Phase 3)
#
# An EventBridge rule watches the state machine for FAILED / TIMED_OUT /
# ABORTED and publishes to an SNS topic.
#
# TWO KNOWN PROBLEMS, both deliberately left for Phase 11 rather than fixed
# here, because Phase 3's acceptance criterion is a zero-diff plan:
#
#   1. The topic policy allows only events.amazonaws.com to publish. The moment
#      CloudWatch alarms are added they will publish as cloudwatch.amazonaws.com
#      and fail SILENTLY.
#   2. One topic will end up mixing two audiences -- "pipeline failed"
#      (operational) and "buy signal on BTC" (business). Phase 11 splits this
#      into -ops-alerts and -model-signals before the email becomes noise.
# =============================================================================

# If StateFunctions run fails, send alert about failure
# 1) SNS topic + suscripción
resource "aws_sns_topic" "sfn_alerts" {
  name = "near-real-time-crypto-sfn-alerts-${var.environment}"
}

resource "aws_sns_topic_subscription" "sfn_alerts_email" {
  topic_arn = aws_sns_topic.sfn_alerts.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# Permitir a EventBridge publicar en el topic
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowEventsToPublish"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.sfn_alerts.arn]
  }
}
resource "aws_sns_topic_policy" "sfn_alerts_policy" {
  arn    = aws_sns_topic.sfn_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

#2) EventBridge rule that detects failed state machine executions
resource "aws_cloudwatch_event_rule" "sfn_failed" {
  name        = "near-real-time-crypto-sfn-failed-${var.environment}"
  description = "Notifica si la ejecución del Step Functions falla/timeout/abort"
  event_pattern = jsonencode({
    "source" : ["aws.states"],
    "detail-type" : ["Step Functions Execution Status Change"],
    "detail" : {
      "stateMachineArn" : [var.state_machine_arn],
      "status" : [
        "FAILED",
        "TIMED_OUT",
        "ABORTED"
      ]
    }
  })
}

# 3) Target: SNS
resource "aws_cloudwatch_event_target" "sfn_failed_to_sns" {
  rule = aws_cloudwatch_event_rule.sfn_failed.name
  arn  = aws_sns_topic.sfn_alerts.arn

  # Was "terraform-20251012021255924500000001". See the note in
  # modules/ingestion/main.tf -- pinned for the Phase 1 import, readable now.
  target_id = "sfn-failure-to-sns"
}

# =============================================================================
# Cost guard -- AWS Budgets  (roadmap.md, Phase 5)
#
# Phase 5 is where this project stops being free. It is put in place NOW, while
# the streaming gate is still closed and the account bills ~$0, precisely so it
# is already watching on the day the gate opens -- a budget added after a
# surprise bill is a post-mortem, not a control.
#
# WHY BUDGETS AND NOT A CLOUDWATCH ALARM ON EstimatedCharges. Two reasons, and
# the second one matters more than it looks:
#
#   1. The AWS/Billing metric only publishes if "Receive Billing Alerts" has been
#      ticked by hand in account preferences -- a console click Terraform cannot
#      make and cannot see. An alarm on a metric that is never published sits in
#      INSUFFICIENT_DATA forever and looks exactly like an alarm that is fine.
#      This project's first ground rule is that clicking in the console is never
#      the answer; a control that silently depends on a click is worse than none.
#
#   2. It notifies by email DIRECTLY, not through the SNS topic above. That
#      dodges the known defect documented at the top of this file: the topic
#      policy allows only events.amazonaws.com to publish, so a notification
#      arriving as budgets.amazonaws.com would be dropped SILENTLY. Phase 11
#      fixes the topic; until it does, the cost guard does not depend on it.
#
# Scope is the whole account, not this project -- account 913524903233 is shared
# with other projects, so an account-wide budget is the one that catches "some
# other stack of mine started billing" as well.
#
# Two thresholds: 80% forecast (an early warning that the month is trending
# over) and 100% actual (it happened). The first is the one that is meant to be
# actionable.
# =============================================================================

resource "aws_budgets_budget" "account_monthly" {
  name         = "crypto-account-monthly-${var.environment}"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.sns_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.sns_email]
  }
}
