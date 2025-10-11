locals {
  sfn_definition = jsonencode({
    Comment = "Daily Gold Pipeline for Crypto (Silver -> Gold Features -> Gold OHLC -> Gold ML -> Silver Crawler)"
    StartAt = "SilverJob"
    States  = {
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
            Type        = "Task"
            Resource    = "arn:aws:states:::glue:startJobRun.sync"
            Parameters  = {JobName = var.glue_job_gold_features}
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
            Retry = [{
            ErrorEquals     = [
                "ThrottlingException",
                "Glue.CrawlerRunningException",
                "States.TaskFailed"
            ]
            IntervalSeconds = 15
            BackoffRate     = 2.0
            MaxAttempts     = 5
            }]
            Next = "WaitCrawler"
        }

        WaitCrawler = {
            Type = "Wait"
            Seconds = 30
            Next = "GetCrawler"
        }
    }
  })
}