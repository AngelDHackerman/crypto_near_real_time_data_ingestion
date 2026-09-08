# =============================================================================
# CloudWatch alarms  (roadmap.md, Phase 11)
#
# NONE OF THESE COULD HAVE WORKED BEFORE THIS PHASE. A CloudWatch alarm
# publishes as cloudwatch.amazonaws.com, and the old topic policy allowed only
# events.amazonaws.com -- so every alarm below would have gone to ALARM state,
# reported that it notified, and notified nobody. That is why Phase 3 wrote the
# policy defect down as something that "will cost debugging time if not fixed up
# front": it is not an error, it is a silence.
#
# ALARMS ARE NOT FREE, so the set is chosen rather than exhaustive: the first 10
# per account are on the free tier and each one after is $0.10/month, in an
# account shared with other projects. Three alarms exist while the project is
# dormant; the rest appear with the gate they belong to, so the count tracks
# what is actually running.
#
# EVERY ALARM SETS treat_missing_data EXPLICITLY, and the value differs by what
# the metric means. This is the setting that quietly decides whether an alarm
# works:
#
#   notBreaching  -- for ERROR COUNTS. No data means nothing failed, which is
#                    the good state. The default (`missing`) would leave these
#                    in INSUFFICIENT_DATA forever on an idle pipeline, which
#                    looks identical to an alarm that is fine.
#   breaching     -- for LIVENESS. No data means the thing that should be
#                    emitting is not running, which is the whole point. An
#                    ECS producer that died stops publishing metrics; an alarm
#                    that ignores absence would never fire for exactly the
#                    failure it exists to catch.
# =============================================================================

# --- Always on: the daily batch pipeline -------------------------------------

resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name        = "${var.name_prefix}-sfn-executions-failed-${var.environment}"
  alarm_description = "The daily Silver -> Gold state machine failed. Redundant with the EventBridge rule on purpose: that rule watches execution STATE CHANGES, this watches a metric, and they fail in different ways. A duplicate alert costs a delete; a missing one costs the incident."

  namespace   = "AWS/States"
  metric_name = "ExecutionsFailed"
  dimensions  = { StateMachineArn = var.state_machine_arn }

  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "sfn_timed_out" {
  alarm_name        = "${var.name_prefix}-sfn-executions-timed-out-${var.environment}"
  alarm_description = "A pipeline execution hit the state machine timeout. Separate from the failure alarm because the fix is different: a failure is usually a job, a timeout is usually a job that is still running and should not be."

  namespace   = "AWS/States"
  metric_name = "ExecutionsTimedOut"
  dimensions  = { StateMachineArn = var.state_machine_arn }

  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "extractor_errors" {
  alarm_name        = "${var.name_prefix}-cmc-extractor-errors-${var.environment}"
  alarm_description = "The CoinMarketCap extractor Lambda is erroring. It is the only source of market-cap context, and it fails quietly: the pipeline downstream reads an empty prefix and produces a smaller table, not an error."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = var.extractor_function_name }

  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

# --- With the streaming gate --------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "producer_not_running" {
  count = var.streaming_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-producer-not-running-${var.environment}"
  alarm_description = "The Binance producer has no running task. THE defining failure of a streaming ingest: nothing errors, the WebSocket simply stops being read, and the first sign is a gap in a table nobody queries for a week."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  dimensions = {
    ClusterName = var.producer_cluster_name
    ServiceName = var.producer_service_name
  }

  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # BREACHING, not notBreaching. A dead service stops publishing this metric
  # altogether, so treating absence as healthy would make this alarm blind to
  # precisely the outage it exists for.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "firehose_stale" {
  count = var.streaming_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-firehose-data-freshness-${var.environment}"
  alarm_description = "Firehose has not delivered to S3 recently. Threshold is 15 minutes against a 300-second buffer -- three missed flushes, not one, so a slow minute is not an incident."

  namespace   = "AWS/Firehose"
  metric_name = "DeliveryToS3.DataFreshness"
  dimensions  = { DeliveryStreamName = var.firehose_stream_name }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

# --- With the serving gate ----------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "endpoint_5xx" {
  count = var.serving_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-endpoint-5xx-${var.environment}"
  alarm_description = "The inference endpoint is returning server errors."

  namespace   = "AWS/SageMaker"
  metric_name = "Invocation5XXErrors"
  dimensions = {
    EndpointName = var.endpoint_name
    VariantName  = "AllTraffic"
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "endpoint_latency" {
  count = var.serving_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-endpoint-latency-${var.environment}"
  alarm_description = "Model latency has regressed past the budget Phase 9's promotion gate enforces. The same 500 ms number in both places: a model that would not be promoted today should not keep serving unnoticed."

  namespace           = "AWS/SageMaker"
  metric_name         = "ModelLatency"
  extended_statistic  = "p95"
  dimensions          = { EndpointName = var.endpoint_name, VariantName = "AllTraffic" }
  period              = 300
  evaluation_periods  = 2
  threshold           = var.endpoint_latency_budget_ms * 1000 # the metric is MICROseconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "inference_lambda_errors" {
  count = var.serving_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-inference-errors-${var.environment}"
  alarm_description = "The inference Lambda is erroring. Note that a 422 is NOT an error here -- an unscoreable symbol returns a status code, not an exception -- so this fires on genuine faults rather than on thin history."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = var.inference_function_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = var.tags
}
