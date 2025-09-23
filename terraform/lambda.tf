# resource "aws_lambda_function" "fetch_top10_crypto" {
#   function_name         = "fetch-top10-crypto-${var.environment}"
#   role                  = aws_iam_role.lambda_role.arn
#   handler       = "app.handler"
#   runtime       = "python3.12"
#   filename      = "build/fetch_top10.zip"  # make sure to generate this file in the repo
#   timeout       = 120
#   memory_size   = 512
#   environment {
#     variables = {
#       RAW_BUCKET    = var.bucket_lake_raw_name
#       BRONZE_PREFIX = var.bronze_prefix
#       SECRET_ARN    = var.secrets_manager_arn
#       TOP_LIST_ID      = join(",", var.top10_list_id)
#     }
#   }
# }
# resource "aws_cloudwatch_log_group" "lambda_logs" {
#   name                  = "/aws/lambda/${aws_lambda_function.fetch_top10_crypto.function_name}"
#   retention_in_days     = 14
# }