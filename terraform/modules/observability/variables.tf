variable "environment" {
  description = "Environment name. Suffixes the topic and the failure rule."
  type        = string
}

variable "sns_email" {
  description = "Address subscribed to the alerts topic."
  type        = string
}

variable "state_machine_arn" {
  description = "ARN of the state machine to watch for FAILED / TIMED_OUT / ABORTED executions. Comes from module.orchestration."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly budget in USD. Notifies at 80% forecast and 100% actual, by email directly -- not through the SNS topic, whose policy would silently drop a budgets.amazonaws.com publish."
  type        = number
  default     = 40
}
