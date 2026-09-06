# =============================================================================
# Streaming ingestion -- Kinesis Data Streams + Firehose  (roadmap.md, Phase 5)
#
# This file is the second half of "ingestion": main.tf holds the CoinMarketCap
# poller, this holds the Binance streaming path. Same module on purpose -- both
# put raw data into the bronze bucket, and the module header in main.tf said so
# before either of these resources existed.
#
# EVERYTHING HERE IS GATED ON var.streaming_enabled, WHICH DEFAULTS TO FALSE.
#
# That is not the same gate as the extractor's `rule_enabled`, and the
# difference is the whole point. A DISABLED EventBridge rule is free, so it can
# exist while switched off. A Kinesis shard is NOT: it bills ~$10.95/month from
# the moment it is created, at zero traffic, and on-demand is worse
# (~$29.20/month in stream-hours before a byte is written). So dormancy here has
# to mean count = 0 -- the stream must not exist, not merely sit idle.
#
# The result is that `terraform apply` builds the complete, reviewable streaming
# stack for $0/month, and waking it up is one variable rather than a rebuild.
# See "Current state: DORMANT" in roadmap.md.
#
# WHY PROVISIONED AND NOT ON_DEMAND. Phase 4 measured the load on the wire
# rather than estimating it: 17.4 KB/s and ~70 records/s after batching, against
# a single shard's 1 MB/s and 1,000 records/s -- 60x and 14x headroom. One shard
# is $10.95/month flat; on-demand's stream-hour charge alone is $29.20 before
# any data. On-demand earns its premium on unpredictable spiky load, and this
# load is neither. See data_sources.md section 9.
# =============================================================================

locals {
  # The stream's name is owned here, in one place. producer.tf composes the
  # stream ARN from it rather than referencing the resource, because the
  # resource has count = 0 while dormant and the producer's IAM policy must
  # exist regardless. One owner for the fact, two readers.
  kinesis_stream_name = "crypto-binance-ticks-${var.environment}"
  kinesis_stream_arn  = "arn:aws:kinesis:${var.aws_region}:${var.aws_account_id}:stream/${local.kinesis_stream_name}"
}

resource "aws_kinesis_stream" "binance_ticks" {
  count = var.streaming_enabled ? 1 : 0

  name             = local.kinesis_stream_name
  retention_period = var.kinesis_retention_hours

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
  shard_count = var.kinesis_shard_count

  # The stream exists so that Phase 13's feedback loop can add a second,
  # independent consumer later. A producer writing straight to Firehose would be
  # ~$1.50/month cheaper and would delete exactly that possibility, along with
  # replay. The trade-off is recorded in data_sources.md section 9.
  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "WriteProvisionedThroughputExceeded",
  ]

  tags = {
    Name = local.kinesis_stream_name
  }
}

# -----------------------------------------------------------------------------
# Firehose -- stream to bronze
#
# The producer does NOT write here directly. Firehose reads the Kinesis stream,
# buffers, compresses and lands objects in bronze under its own source prefix.
# -----------------------------------------------------------------------------
resource "aws_kinesis_firehose_delivery_stream" "binance_to_bronze" {
  count = var.streaming_enabled ? 1 : 0

  name        = "crypto-binance-to-bronze-${var.environment}"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.binance_ticks[0].arn
    role_arn           = aws_iam_role.firehose[0].arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose[0].arn
    bucket_arn = var.bronze_bucket_arn

    # Top level inside a lake bucket is the SOURCE, never the layer -- the
    # bucket already names the layer. Same rule Phase 2.1 applied to `cmc/`.
    #
    # The !{timestamp:...} expressions are evaluated by Firehose at delivery
    # time, not by Terraform. No escaping is needed: `!{` is not an
    # interpolation sequence in HCL, only `${` is.
    #
    # =========================================================================
    # PHASE 6 DECISION: NATIVE PREFIX, NOT DYNAMIC PARTITIONING. Verified
    # against the AWS docs and pricing on 2026-09-05; the numbers are below so
    # the choice can be re-checked rather than believed.
    #
    # The premise Phase 6 was written on was WRONG. It assumed Firehose can
    # only write `YYYY/MM/DD/HH/` unless dynamic partitioning is switched on.
    # It cannot: the `timestamp` namespace works in a plain prefix, with no
    # dynamic partitioning and no surcharge, and AWS's own documentation shows
    # this exact Hive-style form as an example. So there was never a trade-off
    # between "Hive layout" and "free" -- only between "partition by symbol"
    # and "free". Phase 5 already wrote the free one.
    #
    # What dynamic partitioning would have added is a `symbol=` level, priced
    # at measured volume (47 GB/month, 45 symbols -- data_sources.md section 9):
    #
    #   $0.020/GB processed                47 GB      = $0.94/mo
    #   $0.005 per 1,000 objects delivered 388,800    = $1.94/mo
    #   S3 PUT on those same objects                  = $1.94/mo
    #   $0.07 per JQ processing hour       unit is genuinely ambiguous in AWS's
    #                                      own docs; worst case (wall clock)
    #                                      $51/mo, best case ~$0
    #
    # ~$4.80/month before JQ, on a $12.62/month ingestion path -- +38% -- to
    # buy a path component that is ALREADY A FIELD IN EVERY PAYLOAD (`s`).
    #
    # Three reasons beyond the money, any one of which is decisive:
    #
    #   1. IT IS A ONE-WAY DOOR. Dynamic partitioning can only be enabled when
    #      a Firehose stream is CREATED, and once enabled it can never be
    #      disabled. Wrong here means destroy and recreate.
    #   2. IT WOULD MULTIPLY THE OBJECT COUNT BY 45. Each symbol gets its own
    #      buffer, so 288 objects/day of ~1 MB becomes 12,960/day of ~24 KB.
    #      That is precisely the small-file problem the 300 s buffer below was
    #      chosen to avoid, reintroduced at 45x. The daily Silver job would
    #      open 12,960 objects to read the same bytes.
    #   3. OUR RECORDS ARE AGGREGATED. The producer batches ~15-35 events into
    #      one newline-delimited Kinesis record, so dynamic partitioning would
    #      additionally need multi-record deaggregation -- another mode to
    #      configure and another place data can be dropped silently.
    #
    # WHAT THIS CHOICE COSTS, STATED RATHER THAN HIDDEN. `!{timestamp:...}`
    # evaluates to the APPROXIMATE ARRIVAL TIMESTAMP OF THE OLDEST RECORD in
    # the object being written -- NOT the event time. So `year=/month=/day=/
    # hour=` below is an ARRIVAL-time partition: an object under `hour=14/`
    # can legitimately contain events from 13:55, because the buffer opened
    # then. Anything that reads this path as event time is wrong at every
    # hour boundary, silently.
    #
    # Two things follow, and both are enforced elsewhere:
    #   - The event timestamp travels INSIDE the payload. Binance sends `E`
    #     (event time) and `T` (trade time) on every frame and the producer
    #     adds `_ingested_at`; producer.py never strips them.
    #   - Silver derives event_time_utc from the payload and re-partitions on
    #     it. Nothing downstream reads this prefix as time; it is a pruning
    #     hint for the reader and a bucketing scheme for S3, nothing more.
    #
    # Dynamic partitioning COULD have fixed that, via partitionKeyFromQuery on
    # the payload's own timestamp -- that is the one thing it genuinely buys.
    # Rejected anyway: Silver re-partitions on event time regardless, so the
    # fix would be paid for twice and used once.
    # =========================================================================
    prefix              = "${var.bronze_streaming_prefix}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "${var.bronze_streaming_prefix}_errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    # BUFFERING, AND WHY THESE TWO NUMBERS.
    # Firehose flushes on whichever limit is hit first. At the measured 17.4
    # KB/s, 5 MiB takes ~5 minutes to fill, so the SIZE limit is what would bind
    # on a quiet market and the INTERVAL is what actually fires. 300 s is chosen
    # over the 60 s minimum deliberately: 60 s would write ~1,440 objects/day of
    # ~1 MB each, and thousands of small objects is precisely the Bronze layout
    # problem Phase 6 exists to fix. 300 s gives ~288 objects/day at ~5 MB --
    # near the size Athena and Spark actually want to read.
    #
    # The cost of that choice is stated rather than hidden: bronze lands up to
    # 5 minutes behind the tick. The "near real time" claim in this project's
    # name is about the INGESTION path, which is sub-second into Kinesis; the
    # lake is deliberately batched behind it. Anything needing true real time
    # reads the stream, not S3 -- which is the second reason the stream exists.
    buffering_size     = var.firehose_buffer_mb
    buffering_interval = var.firehose_buffer_seconds

    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose[0].name
      log_stream_name = "S3Delivery"
    }
  }

  tags = {
    Name = "crypto-binance-to-bronze-${var.environment}"
  }
}

resource "aws_cloudwatch_log_group" "firehose" {
  count = var.streaming_enabled ? 1 : 0

  name              = "/aws/kinesisfirehose/crypto-binance-to-bronze-${var.environment}"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# IAM -- Firehose: read the one stream, write the one prefix
#
# Scoped by ARN in both directions, never "*". Phase 3's key principle: the IAM
# lives next to the resource it serves.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  count = var.streaming_enabled ? 1 : 0

  name = "firehose-binance-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "firehose.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "firehose" {
  count = var.streaming_enabled ? 1 : 0

  statement {
    sid = "ReadTheBinanceStream"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.binance_ticks[0].arn]
  }

  # Firehose needs multipart-upload actions, not just PutObject: a 5 MB GZIP
  # buffer is delivered as a multipart upload.
  statement {
    sid = "WriteBronzeStreamingPrefixOnly"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [
      "${var.bronze_bucket_arn}/${var.bronze_streaming_prefix}/*",
      "${var.bronze_bucket_arn}/${var.bronze_streaming_prefix}_errors/*",
    ]
  }

  statement {
    sid       = "ListBucketForDelivery"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.bronze_bucket_arn]
  }

  statement {
    sid       = "WriteItsOwnLogs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  count = var.streaming_enabled ? 1 : 0

  name   = "firehose-binance-policy-${var.environment}"
  role   = aws_iam_role.firehose[0].id
  policy = data.aws_iam_policy_document.firehose[0].json
}
