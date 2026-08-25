output "alerts_topic_arn" {
  description = "ARN of the SNS topic carrying pipeline failure alerts."
  value       = aws_sns_topic.sfn_alerts.arn
}
