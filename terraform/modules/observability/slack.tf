# =============================================================================
# Slack delivery for model signals  (roadmap.md, Phase 11)
#
# GATED, and the gate is not about cost -- a Lambda and a secret cost nothing at
# rest. It is about a credential that does not exist yet. `slack_enabled = true`
# with an empty secret creates a subscription that fails on every message, and
# the failure surfaces as a Lambda error rather than as "you forgot to paste the
# webhook". Off until the value is in Secrets Manager, which is one deliberate
# step by a human, like every other credential in this project.
#
# The secret RESOURCE is created either way and holds a placeholder. Terraform
# owns the container; a human puts the credential in it, out of band, exactly as
# with the CoinMarketCap key. `ignore_changes` on the version is what keeps the
# next apply from overwriting the real value with the placeholder again -- which
# is the classic way this pattern goes wrong.
# =============================================================================

resource "aws_secretsmanager_secret" "slack_webhook" {
  name        = "${var.name_prefix}-slack-webhook-${var.environment}"
  description = "Incoming webhook for model signals. A bearer credential: anyone holding it can post to the channel as this app. Set the value by hand; Terraform owns the container, not the contents."

  # Long enough to recover a webhook someone deleted by accident, short enough
  # that a rotated credential does not linger. Seven is the AWS minimum.
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "slack_webhook_placeholder" {
  secret_id     = aws_secretsmanager_secret.slack_webhook.id
  secret_string = jsonencode({ webhook_url = "REPLACE_ME" })

  lifecycle {
    # Without this, every apply after someone sets the real webhook would put
    # the placeholder back -- and the symptom would be Slack silently going
    # quiet at an unrelated moment, hours after the apply that caused it.
    ignore_changes = [secret_string]
  }
}

data "archive_file" "slack_notifier" {
  count = var.slack_enabled ? 1 : 0

  type        = "zip"
  source_file = var.slack_notifier_source_file
  output_path = var.slack_notifier_build_path
}

data "aws_iam_policy_document" "slack_notifier_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack_notifier" {
  count = var.slack_enabled ? 1 : 0

  name               = "${var.name_prefix}-slack-notifier-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.slack_notifier_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "slack_notifier" {
  count = var.slack_enabled ? 1 : 0

  statement {
    sid       = "ReadTheWebhook"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_webhook.arn]
  }

  # Resource = "*" justified: the log group name embeds the function name, which
  # Terraform resolves at apply time. Same justification as every other role
  # here.
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "slack_notifier" {
  count = var.slack_enabled ? 1 : 0

  name   = "slack-notifier-access"
  role   = aws_iam_role.slack_notifier[0].id
  policy = data.aws_iam_policy_document.slack_notifier[0].json
}

resource "aws_lambda_function" "slack_notifier" {
  count = var.slack_enabled ? 1 : 0

  function_name    = "${var.name_prefix}-slack-notifier-${var.environment}"
  role             = aws_iam_role.slack_notifier[0].arn
  handler          = "app.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slack_notifier[0].output_path
  source_code_hash = data.archive_file.slack_notifier[0].output_base64sha256
  memory_size      = 128
  timeout          = 15

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
    }
  }

  tags = var.tags
}

resource "aws_lambda_permission" "sns_invoke_slack" {
  count = var.slack_enabled ? 1 : 0

  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.model_signals.arn
}

resource "aws_sns_topic_subscription" "signals_to_slack" {
  count = var.slack_enabled ? 1 : 0

  topic_arn = aws_sns_topic.model_signals.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier[0].arn
}

# The notifier's own failures go to OPS, by email -- deliberately not to Slack.
# Routing "Slack delivery is broken" through Slack is the one alert that cannot
# work, and it is the kind of loop that looks fine in a diagram.
resource "aws_cloudwatch_metric_alarm" "slack_notifier_errors" {
  count = var.slack_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-slack-notifier-errors-${var.environment}"
  alarm_description   = "The Slack notifier is failing, so model signals are being lost. Delivered by email on purpose: the broken channel cannot carry the news that it is broken."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.slack_notifier[0].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}
