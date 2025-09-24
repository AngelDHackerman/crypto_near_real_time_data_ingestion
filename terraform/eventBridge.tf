# Create rule
resource "aws_cloudwatch_event_rule" "extractor_schedule" {
  name                  = "schedule-fetch-top10-${var.environment}"
  description           = "Triggers lambda of extractor on API CMC, in env: ${var.environment}"
  schedule_expression   = var.eventbridge_schedule_expression
  state                 = var.eventbridge_rule_enabled ? "ENABLED" : "DISABLED"
}

# Target: Lambda extractor
resource "aws_cloudwatch_event_target" "extractor_target" {
  rule = aws_cloudwatch_event_rule.extractor_schedule.name
  arn = aws_lambda_function.fetch_top10_crypto.arn
}

# Allow EventBridge to invoke Lambda extractor
resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id      = "AllowEventBridgeInvoke"
  action            = "lambda:InvokeFunction"
  function_name     = aws_lambda_function.fetch_top10_crypto.function_name
  principal         = "events.amazonaws.com"
  source_arn        = aws_cloudwatch_event_rule.extractor_schedule.arn
}