#############################
# Glue Job: Gold Features Base
#############################

resource "aws_glue_job" "gold_ml_features" {
  name                = "gold-ml-training-cmc-${var.environment}"
  role_arn            = aws_iam_role.glue_gold_base.arn
  glue_version        = "4.0"
  number_of_workers   = 2
  worker_type         = "G.1X"
  max_retries         = 1
  timeout             = 30
  execution_class       = "FLEX" # flex is a cheaper option

  command {
    name              = "glueetl"
    python_version    = "3"
    script_location   = "s3://${var.bucket_artifacts_name}/jobs/gold_ml_training_job.py"
  }

  # Pass the parameters required by gold_ml_training_job.py 
  # (match getResolvedOptions of the script: SILVER_BUCKET, SILVER_PREFIX, GOLD_BUCKET, GOLD_FEATURES_PREFIX, PROCESS_FROM) :contentReference[oaicite:2]{index=2}
  default_arguments = {
    "--job-language"                         = "python"
    "--enable-continuous-cloudwatch-log"     = "true"
    "--enable-metrics"                       = "true"
    "--enable-glue-datacatalog"              = "true"
    "--TempDir"                              = "s3://${var.bucket_artifacts_name}/tmp/"

    # Business Arguments
    "--JOB_NAME"              = "gold-ml-training-cmc-${var.environment}"
    "--GOLD_BUCKET"           = var.bucket_silver_gold_name
    "--GOLD_FEATURES_PREFIX"  = var.gold_features_prefix
    "--GOLD_ML_PREFIX"        = var.gold_ml_prefix
  }

  tags = var.tags
}