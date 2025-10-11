locals {
  sfn_definition = jsonencode({
    Comment = "Daily Gold Pipeline for Crypto (Silver -> Gold Features -> Gold OHLC -> Gold ML -> Silver Crawler)"
    StartAt = "SilverJob"
    States = {
      SilverJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.glue_job_silver }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldFeaturesBaseJob"
      }

      GoldFeaturesBaseJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.glue_job_gold_features }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldOHLCJob"
      }

      GoldOHLCJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.glue_job_gold_ohlc }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "GoldMLTrainingJob"
      }

      GoldMLTrainingJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = var.glue_job_gold_ml }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          BackoffRate     = 2.0
          MaxAttempts     = 3
        }]
        Next = "StartCrawler"
      }

      StartCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = var.silver_crawler_name }
        Retry = [
          {
            # Retry only on specific known transient Glue/Throttle errors
            ErrorEquals     = ["ThrottlingException", "Glue.CrawlerRunningException"]
            IntervalSeconds = 15
            BackoffRate     = 2.0
            MaxAttempts     = 5
          },
          {
            # Catch-all retry must be in its own block with States.ALL alone
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 15
            BackoffRate     = 2.0
            MaxAttempts     = 3
          }
        ]
        Next = "WaitCrawler"
      }

      WaitCrawler = {
        Type    = "Wait"
        Seconds = 180
        Next    = "GetCrawler"
      }

      GetCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = { Name = var.silver_crawler_name }
        ResultSelector = {
          # State.$ creates $.State from the JSON path $.Crawler.State returned by the task
          "State.$" = "$.Crawler.State"
        }
        Next = "CrawlerDoneChoice"
      }

      CrawlerDoneChoice = {
        Type = "Choice"
        Choices = [
          # if crawler is READY -> success
          { Variable = "$.State", StringEquals = "READY", Next = "Success" },
          # if crawler still RUNNING -> poll again
          { Variable = "$.State", StringEquals = "RUNNING", Next = "WaitCrawler" }
        ]
        # default: if other unexpected state -> go to WaitCrawler (or consider Fail)
        Default = "WaitCrawler"
      }

      Success = { Type = "Succeed" }
    }
  })
}

resource "aws_sfn_state_machine" "daily_gold_pipeline" {
  name       = "near-real-time-crypto-daily-gold-pipeline"
  role_arn   = aws_iam_role.sfn_role.arn
  definition = local.sfn_definition

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
  }
}

resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/near-real-time-crypto-daily-gold-pipeline"
  retention_in_days = 14
}
