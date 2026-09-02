output "alerts_topic_arn" {
  description = "ARN of the SNS topic carrying pipeline failure alerts."
  value       = aws_sns_topic.sfn_alerts.arn
}

output "budget_name" {
  description = "Name of the account-wide monthly cost budget."
  value       = aws_budgets_budget.account_monthly.name
}
