data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect = "Allow"
    principals { 
        type = "Service" 
        identifiers = ["states.amazonaws.com"] 
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "sfn_role" {
  name               = "sfn-orchestrator-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags = var.tags
}

data "aws_iam_policy_document" "sfn_policy" {
  statement {
    sid     = "GlueJobs"
    effect  = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Crawler"
    effect  = "Allow"
    actions = [
      "glue:StartCrawler",
      "glue:GetCrawler"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "sfn_policy" {
  name   = "sfn-orchestrator-crypto-policy"
  policy = data.aws_iam_policy_document.sfn_policy.json
}

resource "aws_iam_role_policy_attachment" "sfn_attach" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = aws_iam_policy.sfn_policy.arn
}
