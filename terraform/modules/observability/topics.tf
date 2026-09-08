# =============================================================================
# Alerting topics, split by audience  (roadmap.md, Phase 11)
#
# Phase 3 recorded two defects here and deliberately left both for this phase,
# because Phase 3's acceptance criterion was a zero-diff plan. Both are fixed
# now, and one of them was worse than it was originally described.
#
# ---------------------------------------------------------------------------
# DEFECT 1: THE TOPIC POLICY WOULD HAVE DROPPED EVERY ALARM, SILENTLY
# ---------------------------------------------------------------------------
# The old policy allowed exactly one publisher: events.amazonaws.com. A
# CloudWatch alarm publishes as cloudwatch.amazonaws.com and a budget as
# budgets.amazonaws.com, and an SNS publish denied by a topic policy does not
# raise anywhere the caller can see -- the alarm goes to ALARM state, reports
# that it notified, and nobody is notified. Phase 5 already had to route the
# budget's notifications around this by emailing directly.
#
# So Phase 11 could not add a single alarm without fixing it first, which is
# exactly what "this will cost debugging time if not fixed up front" meant.
#
# AND THE FIX ADDS SOMETHING THE ORIGINAL DID NOT ASK FOR: an aws:SourceAccount
# condition. A service principal like cloudwatch.amazonaws.com is not one
# account's CloudWatch -- it is the CloudWatch service, everywhere. Granting it
# Publish with no condition lets an alarm in ANY AWS account publish to this
# topic; someone who learns the ARN can page this project's owner at will. That
# is the confused-deputy problem, and the condition is the standard fix.
#
# ---------------------------------------------------------------------------
# DEFECT 2: ONE TOPIC, TWO AUDIENCES
# ---------------------------------------------------------------------------
# "The nightly pipeline failed" and "BTC crossed a signal threshold" are read by
# different people, at different urgencies, and one of them arrives far more
# often. Mixed into one inbox, the operational alert -- the one that means
# something is broken -- is the one that gets filtered.
#
# THIS COSTS TWO DESTROYS AND ONE MANUAL STEP, stated plainly rather than
# buried: an SNS topic name is ForceNew, so splitting means destroying
# `near-real-time-crypto-sfn-alerts-crypto` and its CONFIRMED email
# subscription. AWS cannot confirm a subscription on anyone's behalf, so after
# the apply there is an email to click. That is the whole cost, and the moment
# to pay it is now -- the project is dormant, nothing is publishing, so no alert
# can be lost in the window. Phase 6 used the same reasoning for its two
# renames.
# =============================================================================

locals {
  # Every principal that will actually publish, rather than the one that did
  # when the policy was written. Firehose is here because Phase 5's delivery
  # stream can be given an error-notification target, and adding a principal
  # later means editing a policy under time pressure during an incident.
  publisher_services = [
    "events.amazonaws.com",     # EventBridge: state machine failures
    "cloudwatch.amazonaws.com", # metric alarms -- the one that was missing
    "budgets.amazonaws.com",    # the cost guard, which currently routes around this
    "firehose.amazonaws.com",
    "sagemaker.amazonaws.com",
  ]
}

resource "aws_sns_topic" "ops_alerts" {
  name         = "${var.name_prefix}-ops-alerts-${var.environment}"
  display_name = "Crypto pipeline ops"
  tags         = var.tags
}

resource "aws_sns_topic" "model_signals" {
  name         = "${var.name_prefix}-model-signals-${var.environment}"
  display_name = "Crypto model signals"
  tags         = var.tags
}

data "aws_iam_policy_document" "topic_policy" {
  for_each = {
    ops     = aws_sns_topic.ops_alerts.arn
    signals = aws_sns_topic.model_signals.arn
  }

  statement {
    sid    = "AllowAwsServicesInThisAccountToPublish"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = local.publisher_services
    }
    actions   = ["SNS:Publish"]
    resources = [each.value]

    # The confused-deputy guard. Without it, "cloudwatch.amazonaws.com may
    # publish" means every CloudWatch in every AWS account may publish.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  arn    = aws_sns_topic.ops_alerts.arn
  policy = data.aws_iam_policy_document.topic_policy["ops"].json
}

resource "aws_sns_topic_policy" "model_signals" {
  arn    = aws_sns_topic.model_signals.arn
  policy = data.aws_iam_policy_document.topic_policy["signals"].json
}

# -----------------------------------------------------------------------------
# Subscriptions -- different channels, because the audiences are different
#
# Ops goes to email: it is low-volume, it needs to arrive even if a webhook is
# broken, and an email survives being read three hours later. Signals go to
# Slack, which is the point of splitting -- a business event in a chat channel
# is glanceable, and the same event in an inbox is the noise that trains someone
# to ignore the inbox.
# -----------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# The signals topic deliberately has NO email subscription, even as a fallback.
# A fallback that duplicates every signal into the inbox recreates exactly the
# problem the split solves, and it would do so invisibly -- the Slack path would
# look like it was working because messages kept arriving somewhere.
