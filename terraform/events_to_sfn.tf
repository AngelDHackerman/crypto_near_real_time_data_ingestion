resource "aws_cloudwatch_event_rule" "daily_gold_silver" {
  name                = "near-real-time-dialy-gold-silver-${var.environment}"
  schedule_expression = var.sfn_daily_schedule_cron
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
}
