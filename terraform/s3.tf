resource "aws_s3_bucket" "lake_raw_data" {
  bucket = "lake-raw-data-bronze-${var.environment}"

  tags = {
    Name        = "lake-raw-data-bronze-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}