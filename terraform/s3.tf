# --- BRONZE ---
resource "aws_s3_bucket" "lake_raw_data" {
  bucket = "lake-raw-data-bronze-${var.environment}"

  tags = {
    Name        = "lake-raw-data-bronze-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

resource "aws_s3_bucket_versioning" "lake_raw_data" {
  bucket = aws_s3_bucket.lake_raw_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake_raw_data" {
  bucket = aws_s3_bucket.lake_raw_data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# --- CURATED (Silver/Gold) ---
resource "aws_s3_bucket" "lake_curated_data" {
  bucket = "lake-curated-data-silver-gold-${var.environment}"

  tags = {
    Name        = "lake-curated-data-silver-gold-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}

resource "aws_s3_bucket_versioning" "lake_curated_data" {
  bucket = aws_s3_bucket.lake_curated_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake_curated_data" {
  bucket = aws_s3_bucket.lake_curated_data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# --- ARTIFACTS ---
resource "aws_s3_bucket" "artifacts-crypto" {
  bucket = "artifacts-crypto-data-${var.environment}"

  tags = {
    Name        = "artifacts-crypto-data-${var.environment}"
    Environment = var.environment
    Owner       = "Angel Hackerman"
    Project     = "Crypto Near Real Time Data Ingestion"
  }
}