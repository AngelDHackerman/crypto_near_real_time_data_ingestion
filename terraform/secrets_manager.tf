# Create a secret in AWS secrest manager 
resource "aws_secretsmanager_secret" "near_real_time_crypto" {
  name        = "near_real_time_crypto_ingestion_secrets"
  description = "Secrets for Near Real-Time Crypto Ingestion"
  
  tags = {
    Project = "Crypto Near Real Time Data Ingestion"
    Env     = var.environment
  }
}
