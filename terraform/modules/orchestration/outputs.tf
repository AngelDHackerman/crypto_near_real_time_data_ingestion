output "state_machine_arn" {
  description = "ARN of the daily Gold pipeline state machine. The observability module watches it for failed executions."
  value       = aws_sfn_state_machine.daily_gold_pipeline.arn
}

output "state_machine_name" {
  description = "Name of the daily Gold pipeline state machine."
  value       = aws_sfn_state_machine.daily_gold_pipeline.name
}
