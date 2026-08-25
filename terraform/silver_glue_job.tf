resource "aws_glue_job" "silver_job" {
  name              = "silver-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 60
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.artifacts.id}/jobs/silver_glue_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"           = "silver-cmc-${var.environment}"
    "--RAW_BUCKET"         = aws_s3_bucket.bronze.id
    "--RAW_PREFIX"         = var.bronze_prefix
    "--SILVER_BUCKET"      = aws_s3_bucket.silver.id
    "--SILVER_PREFIX"      = var.silver_prefix
    "--PARTITION_BY_ASSET" = "false"

    "--enable-glue-datacatalog"          = "true"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    "--conf" = "spark.sql.parquet.compression.codec=snappy --conf spark.sql.shuffle.partitions=8 --conf spark.sql.sources.partitionOverwriteMode=dynamic --conf spark.sql.session.timeZone=UTC"

    # Committer optimizado para S3 → menos archivos corruptos en fallos
    "--enable-s3-parquet-optimized-committer" = "true"

    "--TempDir" = "s3://${aws_s3_bucket.artifacts.id}/tmp/"
  }
}