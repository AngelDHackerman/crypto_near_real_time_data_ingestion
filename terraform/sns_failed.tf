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
      "stateMachineArn" : [aws_sfn_state_machine.daily_gold_pipeline.arn],
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
}
