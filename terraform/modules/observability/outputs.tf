# Phase 11 split one topic into two. `alerts_topic_arn` is gone; the state
# machine's NotifyFailure now publishes to the ops topic explicitly, so the
# consumer names the audience it is addressing rather than "the topic".
output "ops_topic_arn" {
  description = "Operational alerts: pipeline failures, Lambda errors, producer liveness. Email, because it must arrive even if a webhook is broken and it survives being read three hours later."
  value       = aws_sns_topic.ops_alerts.arn
}

output "signals_topic_arn" {
  description = "Model signals. Slack when slack_enabled, and deliberately with no email fallback -- a fallback that duplicates every signal into the inbox recreates the problem the split solves."
  value       = aws_sns_topic.model_signals.arn
}

output "slack_webhook_secret_arn" {
  description = "Container for the Slack webhook. Terraform owns the secret; a human owns its contents."
  value       = aws_secretsmanager_secret.slack_webhook.arn
}

output "budget_name" {
  description = "Name of the account-wide monthly cost budget."
  value       = aws_budgets_budget.account_monthly.name
}
