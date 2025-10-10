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

resource "aws_s3_bucket_lifecycle_configuration" "lake_raw_data" {
  bucket = aws_s3_bucket.lake_raw_data.id

  rule {
    id      = "bronze-30d-to-glacier-ir"
    status  = "Enabled"

    filter { } # applies to all the bucket 

    transition {
      days            = 30
      storage_class   = "GLACIER_IR" # Glacier Instant Retrival
    } 

    # Clean Incomplete Multipart Loads (save some $)
    abort_incomplete_multipart_upload { 
      days_after_initiation = 7 
    }

    # remove no current versions after 365 days
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
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

resource "aws_s3_bucket_lifecycle_configuration" "lake_curated_data" {
  bucket = aws_s3_bucket.lake_curated_data.id

  # Rule JUST for the Silver prefix
  rule {
    id        = "silver-to-onezone-ia"
    status    = "Enabled"

    filter {
      prefix = "top10/silver/"
    }

    transition {
      days            = 360
      storage_class   = "ONEZONE_IA"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }

  # Gold: without transition (it will stay in Standard tier)
  rule {
    id        = "gold-keep-standard"
    status    = "Enabled"
    filter {
      prefix = "top10/gold/"
    }
    # clean multipart 
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    # removed passed versioning
    noncurrent_version_expiration {
      noncurrent_days = 90
  }
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

resource "aws_s3_bucket_versioning" "artifacts-crypto" {
  bucket = aws_s3_bucket.artifacts-crypto.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts-crypto" {
  bucket = aws_s3_bucket.artifacts-crypto.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts-crypto.id

  rule {
    id      = "expire-old-artifacts"
    status  = "Enabled"
    filter {
      prefix = ""  # applies to all the bucket
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Upload silver glue job to S3
resource "aws_s3_object" "silver_glue_script" {
  bucket                  = var.bucket_artifacts_name
  key                     = "jobs/silver_glue_job.py"
  source                  = "../glue_jobs_silver_gold/silver/silver_glue_job.py"
  etag                    = filemd5("../glue_jobs_silver_gold/silver/silver_glue_job.py")
  content_type            = "text/x-python"
  server_side_encryption  = "AES256"
}

# Upload gold features base glue job to S3
resource "aws_s3_object" "gold_features_base_glue_script" {
  bucket                  = var.bucket_artifacts_name
  key                     = "jobs/gold_features_base_job.py"
  source                  = "../glue_jobs_silver_gold/gold/gold_features_base_job.py"
  etag                    = filemd5("../glue_jobs_silver_gold/gold/gold_features_base_job.py")
  content_type            = "text/x-python"
  server_side_encryption  = "AES256"
}

# Upload gold machine learning glue job to S3
resource "aws_s3_object" "gold_ml_training_glue_script" {
  bucket                  = var.bucket_artifacts_name
  key                     = "jobs/gold_ml_training_job.py"
  source                  = "../glue_jobs_silver_gold/gold/gold_ml_training_job.py"
  etag                    = filemd5("../glue_jobs_silver_gold/gold/gold_ml_training_job.py")
  content_type            = "text/x-python"
  server_side_encryption  = "AES256"
}

# Upload gold ohlc glue job to S3
resource "aws_s3_object" "gold_ohlc_glue_script" {
  bucket                  = var.bucket_artifacts_name
  key                     = "jobs/gold_ohlc_h_d_w_m.py"
  source                  = "../glue_jobs_silver_gold/gold/gold_ohlc_h_d_w_m.py"
  etag                    = filemd5("../glue_jobs_silver_gold/gold/gold_ohlc_h_d_w_m.py")
  content_type            = "text/x-python"
  server_side_encryption  = "AES256"
}