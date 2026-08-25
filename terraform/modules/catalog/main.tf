# =============================================================================
# Catalog module -- Glue Data Catalog + Athena  (roadmap.md, Phase 3)
#
# The metadata layer over the lake: the two Glue databases, the Silver crawler
# that populates the Silver one, the crawler's IAM role, and the Athena
# workgroup that queries them.
#
# Gold does NOT have a crawler: it uses partition projection with hand-written
# DDL (see sql/athena_projections_*.sql), which is why the Gold crawlers below
# are commented out rather than deleted. Phase 6 migrates Silver to projection
# too and deletes the crawler entirely, along with the four polling states it
# forces into the state machine.
# =============================================================================

# -----------------------------------------------------------------------------
# Glue databases and the Silver crawler
# -----------------------------------------------------------------------------
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
    path = "s3://${var.silver_bucket_id}/${var.silver_prefix}/"
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
#     path        = "s3://${var.gold_bucket_id}/gold_features_base/"
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
#     path        = "s3://${var.gold_bucket_id}/gold_ml_training/"
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

# -----------------------------------------------------------------------------
# IAM for the Silver crawler
# -----------------------------------------------------------------------------
# Trust policy for Glue service
data "aws_iam_policy_document" "glue_crawler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_crawler_role" {
  name               = "${var.project}-glue-crawler-role"
  assume_role_policy = data.aws_iam_policy_document.glue_crawler_assume.json
  tags               = var.tags
}

# Least-privilege policy for Glue crawler
data "aws_iam_policy_document" "glue_crawler_policy" {

  # Silver only. Gold lives in its own bucket now and uses partition projection,
  # so the crawler has no business there -- the prefix conditions that used to
  # keep these two apart inside one shared bucket are gone.
  statement {
    sid = "S3ListSilverBucket"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [var.silver_bucket_arn]
  }

  statement {
    sid       = "S3ReadSilverObjects"
    actions   = ["s3:GetObject"]
    resources = ["${var.silver_bucket_arn}/*"]
  }

  # Glue Catalog actions - restrict
  statement {
    sid = "GlueCatalogAccess"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateDatabase"
    ]
    resources = ["*"]
  }

  statement {
    sid = "GlueCatalogAccessTables"
    actions = [
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable"
    ]
    resources = ["*"]
  }

  # CloudWatch logs
  statement {
    sid       = "CWLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_crawler_policy" {
  name   = "${var.project}-glue-crawler-policy"
  policy = data.aws_iam_policy_document.glue_crawler_policy.json
}

# Attach AWS managed policy for Glue service role (covers many required actions)
resource "aws_iam_role_policy_attachment" "attach_service_role" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Attach your custom least-privilege policy on top
resource "aws_iam_role_policy_attachment" "attach_custom" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = aws_iam_policy.glue_crawler_policy.arn
}

# -----------------------------------------------------------------------------
# Athena workgroup
# -----------------------------------------------------------------------------
resource "aws_athena_workgroup" "workgroup" {
  name = "${var.project}-wg-${var.environment}"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.artifacts_bucket_id}/${var.athena_results_prefix}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  state = "ENABLED"
  tags  = var.tags
}

