#############################
# Glue Job: Gold Open, High, Low, Close 
# views of: hour, day, week and month
#############################

resource "aws_glue_job" "gold_ohlc" {
  name              = "gold-ohlc-day-cmc-${var.environment}"
  role_arn          = aws_iam_role.glue_gold_base.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 1
  timeout           = 30
  execution_class   = "FLEX" # flex is a cheaper option

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.bucket_artifacts_name}/jobs/gold_ohlc_h_d_w_m.py"
  }

  # Pass the parameters required by gold_ohlc_h_d_w_m.py
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${var.bucket_artifacts_name}/tmp/"

    # 🔖 Bookmarks
    "--job-bookmark-option" = "job-bookmark-enable"

    # Business Arguments
    "--JOB_NAME"             = "gold-ohlc-day-cmc-${var.environment}"
    "--GOLD_FEATURES_PREFIX" = var.gold_features_prefix
    "--GOLD_BUCKET"          = var.bucket_silver_gold_name
    "--GOLD_OHLC_PREFIX"     = var.gold_ohlc_prefix
    "--GRAIN"                = "day" # "hour" | "day" | "week" | "month" Option to create another glue job with different time window
  }

  tags = var.tags
}
