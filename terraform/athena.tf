resource "aws_athena_workgroup" "workgroup" {
  name = "${var.project}-wg-${var.environment}"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.artifacts.id}/${var.athena_results_prefix}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  state = "ENABLED"
  tags  = var.tags
}