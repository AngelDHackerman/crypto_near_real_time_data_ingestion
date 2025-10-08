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
  name              = "${var.project}-silver-crawler-${var.environment}"
  role              = aws_iam_role.glue_crawler_role.arn
  database_name     = aws_glue_catalog_database.silver_db.name
  table_prefix      = "silver_"
  
  s3_target {
    path = "s3://${var.bucket_silver_gold_name}/${var.silver_prefix}/"
    exclusions = [
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

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY" # suele ser ideal para particiones por fecha
  }

  configuration = jsonencode({
    Version         = 1.0,
    Grouping        = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
    CrawlerOutput   = {
        Partitions  = { AddOrUpdateBehavior = "InheritFromTable" }
        Tables      = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  # schedule: will be done with stepFunctions

  tags = var.tags
}

# Crawler for Gold Features Base
resource "aws_glue_crawler" "gold_crawler" {
  name            = "${var.project}-gold-feature-base-crawler-${var.environment}"
  role            = aws_iam_role.glue_crawler_role.arn
  database_name   = aws_glue_catalog_database.gold_db.name
  table_prefix    = ""

  s3_target {
    path        = "s3://${var.bucket_silver_gold_name}/top10/gold/gold_features_base/"
    exclusions  = [
      "**/manifest/**",
      "**/status/**",
      "**/_SUCCESS",
      "**/.success",
      "**/*.crc",
      "**/*.json" 
    ]
  }

  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior = "LOG"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0,
    Grouping = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
    CrawlerOutput = {
        Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
        Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  # schedule: will be done with stepFunctions

  tags = var.tags
}

# Crawler for Gold ML Training features
resource "aws_glue_crawler" "gold_crawler_ml" {
  name            = "${var.project}-gold-ml-training-crawler-${var.environment}"
  role            = aws_iam_role.glue_crawler_role.arn
  database_name   = aws_glue_catalog_database.gold_db.name
  table_prefix    = ""

  s3_target {
    path        = "s3://${var.bucket_silver_gold_name}/top10/gold/gold_ml_training/"
    exclusions  = [
      "**/manifest/**",
      "**/status/**",
      "**/_SUCCESS",
      "**/.success",
      "**/*.crc",
      "**/*.json" 
    ]
  }

  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior = "LOG"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0,
    Grouping = { TableLevelConfiguration = 10 } # This will crate a single table for all cryptos
    CrawlerOutput = {
        Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
        Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  # schedule: will be done with stepFunctions

  tags = var.tags
}