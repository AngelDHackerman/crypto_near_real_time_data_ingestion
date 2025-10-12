# SNS topic + suscripción
resource "aws_sns_topic" "sfn_alerts" {
  name = "near-real-time-crypto-sfn-alerts-${var.environment}"
}

resource "aws_sns_topic_subscription" "sfn_alerts_email" {
  topic_arn = aws_sns_topic.sfn_alerts.arn
  protocol  = "email"
  endpoint  = "tu-correo@ejemplo.com" # <-- cambia esto
}