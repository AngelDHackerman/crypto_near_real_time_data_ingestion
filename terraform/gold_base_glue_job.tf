#############################
# Glue Job: Gold Features Base
#############################

resource "aws_glue_job" "gold_features_base" {
  name                  = "gold-base-features-cmc-${var.environment}"
  role_arn              = aws_iam_role.glue_gold_base.arn
  glue_version          = "4.0"
  number_of_workers     = 2
  worker_type           = "G.1X"
  max_retries           = 1
  timeout               = 30
  execution_class       = "FLEX" # flex is a cheaper option

  command {
    name                = "glueetl"
    python_version      = "3"
    script_location     = "s3://${var.bucket_artifacts_name}/jobs/gold_features_base_job.py"
  }

  # Pass the parameters required by gold_features_base.py 
  # (match getResolvedOptions of the script: SILVER_BUCKET, SILVER_PREFIX, GOLD_BUCKET, GOLD_FEATURES_PREFIX, PROCESS_FROM) :contentReference[oaicite:2]{index=2}
  default_arguments = {
    "--job-language"                         = "python"
    "--enable-continuous-cloudwatch-log"     = "true"
    "--enable-metrics"                       = "true"
    "--enable-glue-datacatalog"              = "true"
    "--TempDir"                              = "s3://${var.bucket_artifacts_name}/tmp/"

      # 🔖 Bookmarks
    "--job-bookmark-option"                  = "job-bookmark-enable"

    # Business Arguments
    "--JOB_NAME"                = "gold-base-features-cmc-${var.environment}"
    "--SILVER_BUCKET"           = var.bucket_silver_gold_name
    "--SILVER_PREFIX"           = var.silver_prefix
    "--GOLD_BUCKET"             = var.bucket_silver_gold_name
    "--GOLD_FEATURES_PREFIX"    = var.gold_features_prefix
    
  }

  tags = var.tags
}