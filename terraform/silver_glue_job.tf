resource "aws_glue_job" "silver_job" {
  name                  = "silver-cmc-${var.environment}"
  role_arn              = aws_iam_role.lambda_role.arn
  glue_version          = "4.0"
  number_of_workers     = 2
  worker_type           = "G.1X"

  command {
    name = "glueetl"
    script_location = "s3://${var.bucket_artifacts_name}/jobs/silver_glue_job.py"
    python_version = "3"
  }

  default_arguments = {
    "--RAW_BUCKET"        = "${var.bucket_lake_raw_name}"
    "--RAW_PREFIX"        = "${var.bronze_prefix}"
    "--SILVER_BUCKET"     = "${var.bucket_silver_gold_name}"
    "--SILVER_PREFIX"     = "${var.silver_prefix}"
    "--PARTITION_BY_ASSET"= "true"

    "--enable-glue-datacatalog" = "true"
    "--job-bookmark-option"     = "job-bookmark-enable"
    "--TempDir"                 = "s3://${var.bucket_artifacts_name}/tmp/"
  }
}