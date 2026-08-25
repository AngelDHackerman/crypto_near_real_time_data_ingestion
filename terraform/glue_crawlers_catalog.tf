resource "aws_glue_catalog_database" "silver_db" {
  name = "crypto_silver_db"
  tags = var.tags
}

resource "aws_glue_catalog_database" "gold_db" {
  name = "crypto_gold_db"
  tags = var.tags
}

# Crawler for Silver
resource "aws_glue_crawler" "silver_crawler" {
  name          = "${var.project}-silver-crawler-${var.environment}"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.silver_db.name
  table_prefix  = "silver_"

  s3_target {
    path = "s3://${aws_s3_bucket.silver.id}/${var.silver_prefix}/"
    exclusions = [
      # The "don't touch gold" exclusion is gone: Gold is a separate bucket.
      "**/manifest/**",
      "**/status/**",
      "**/_SUCCESS",
      "**/.success",
      "**/*.crc",
      "**/*.json"
    ]
  }

  # Prefer native blocks instead of configuration JSON
  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior = "LOG"
  }

  # CRAWL_NEW_FOLDERS_ONLY is the right behaviour for date-partitioned data: the
  # crawler only visits partitions it has not seen, which keeps the run cheap.
  #
  # CAVEAT, learned the hard way in Phase 2.1: while this is selected, AWS makes
  # s3_target IMMUTABLE. Any change to the target path is rejected by UpdateCrawler
  # with "Amazon S3 target is immutable when Crawl new folders only is selected".
  # Terraform plans it as an in-place update and the apply fails every time.
  #
  # To change the target, the crawler must be REPLACED, not updated:
  #   terraform apply -replace=aws_glue_crawler.silver_crawler
  #
  # Moot once Phase 6 migrates Silver to partition projection and deletes this
  # crawler along with the polling states in the state machine.
  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version  = 1.0,
    Grouping = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  # schedule: will be done with stepFunctions

  tags = var.tags
}

# # Crawler for Gold Features Base
# resource "aws_glue_crawler" "gold_crawler" {
#   name            = "${var.project}-gold-feature-base-crawler-${var.environment}"
#   role            = aws_iam_role.glue_crawler_role.arn
#   database_name   = aws_glue_catalog_database.gold_db.name
#   table_prefix    = ""

#   s3_target {
#     path        = "s3://${aws_s3_bucket.gold.id}/gold_features_base/"
#     exclusions  = [
#       "**/manifest/**",
#       "**/status/**",
#       "**/_SUCCESS",
#       "**/.success",
#       "**/*.crc",
#       "**/*.json" 
#     ]
#   }

#   schema_change_policy {
#     update_behavior = "LOG"
#     delete_behavior = "LOG"
#   }

#   recrawl_policy {
#     recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
#   }

#   configuration = jsonencode({
#     Version = 1.0,
#     Grouping = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
#     CrawlerOutput = {
#         Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
#         Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
#     }
#   })

#   # schedule: will be done with stepFunctions

#   tags = var.tags
# }

# # Crawler for Gold ML Training features
# resource "aws_glue_crawler" "gold_crawler_ml" {
#   name            = "${var.project}-gold-ml-training-crawler-${var.environment}"
#   role            = aws_iam_role.glue_crawler_role.arn
#   database_name   = aws_glue_catalog_database.gold_db.name
#   table_prefix    = ""

#   s3_target {
#     path        = "s3://${aws_s3_bucket.gold.id}/gold_ml_training/"
#     exclusions  = [
#       "**/manifest/**",
#       "**/status/**",
#       "**/_SUCCESS",
#       "**/.success",
#       "**/*.crc",
#       "**/*.json" 
#     ]
#   }

#   schema_change_policy {
#     update_behavior = "LOG"
#     delete_behavior = "LOG"
#   }

#   recrawl_policy {
#     recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
#   }

#   configuration = jsonencode({
#     Version = 1.0,
#     Grouping = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
#     CrawlerOutput = {
#         Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
#         Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
#     }
#   })

#   # schedule: will be done with stepFunctions

#   tags = var.tags
# }