resource "aws_s3_bucket" "lake_raw_data" {
  bucket = "lake-raw-data-bronze-${var.environment}"

  tags = {
    Name        = "lake-raw-data-bronze-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

resource "aws_s3_bucket" "lake_curated_data" {
  bucket = "lake-curated-data-silver-gold-${var.environment}"

  tags = {
    Name        = "lake-curated-data-silver-gold-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

resource "aws_s3_bucket" "artifacts-crypto" {
  bucket = "artifacts-crypto-data-${var.environment}"

  tags = {
    Name        = "artifacts-crypto-data-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}