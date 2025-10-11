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
    }
  })
}