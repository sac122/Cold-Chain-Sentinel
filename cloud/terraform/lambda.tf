# ── Lambda Functions ──────────────────────────────────────────────────────────
#
# All Lambda functions are packaged as ZIP archives built from
# cloud/lambdas/{name}/.  Terraform uses the archive provider to
# create the ZIP at plan time.

locals {
  lambda_runtime  = "python3.11"
  lambda_timeout  = 30
  lambda_src_path = "${path.module}/../lambdas"
}

# ── Alert Handler ─────────────────────────────────────────────────────────────

data "archive_file" "alert_handler" {
  type        = "zip"
  source_dir  = "${local.lambda_src_path}/alert_handler"
  output_path = "${path.module}/.lambda_zips/alert_handler.zip"
}

resource "aws_lambda_function" "alert_handler" {
  function_name    = "${var.prefix}-alert-handler"
  description      = "Receives cold-chain events from IoT Core, writes to DynamoDB, sends SNS alert"
  role             = aws_iam_role.alert_handler.arn
  runtime          = local.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.alert_handler.output_path
  source_code_hash = data.archive_file.alert_handler.output_base64sha256
  timeout          = local.lambda_timeout
  memory_size      = 256

  environment {
    variables = {
      INCIDENTS_TABLE   = aws_dynamodb_table.incidents.name
      SNS_TOPIC_ARN     = aws_sns_topic.alerts.arn
      AWS_REGION_NAME   = var.aws_region
      INCIDENT_TTL_DAYS = tostring(var.incident_ttl_days)
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda_alerts.name
  }

  depends_on = [aws_iam_role_policy_attachment.alert_basic]

  tags = {
    Name    = "${var.prefix}-alert-handler"
    Purpose = "Cold-chain incident alerting"
  }
}

# ── API Handler ───────────────────────────────────────────────────────────────

data "archive_file" "api_handler" {
  type        = "zip"
  source_dir  = "${local.lambda_src_path}/api_handler"
  output_path = "${path.module}/.lambda_zips/api_handler.zip"
}

resource "aws_lambda_function" "api_handler" {
  function_name    = "${var.prefix}-api-handler"
  description      = "REST API: list devices, incidents, device summary"
  role             = aws_iam_role.api_handler.arn
  runtime          = local.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.api_handler.output_path
  source_code_hash = data.archive_file.api_handler.output_base64sha256
  timeout          = local.lambda_timeout
  memory_size      = 256

  environment {
    variables = {
      INCIDENTS_TABLE  = aws_dynamodb_table.incidents.name
      DEVICES_TABLE    = aws_dynamodb_table.devices.name
      TIMESTREAM_DB    = var.timestream_enabled ? aws_timestreamwrite_database.telemetry[0].database_name : ""
      TIMESTREAM_TABLE = var.timestream_enabled ? aws_timestreamwrite_table.telemetry[0].table_name : ""
      AWS_REGION_NAME  = var.aws_region
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda_api.name
  }

  depends_on = [aws_iam_role_policy_attachment.api_basic]

  tags = {
    Name    = "${var.prefix}-api-handler"
    Purpose = "Cold-chain REST API"
  }
}

# ── Stream Processor ──────────────────────────────────────────────────────────

data "archive_file" "stream_processor" {
  type        = "zip"
  source_dir  = "${local.lambda_src_path}/stream_processor"
  output_path = "${path.module}/.lambda_zips/stream_processor.zip"
}

resource "aws_lambda_function" "stream_processor" {
  function_name    = "${var.prefix}-stream-processor"
  description      = "DynamoDB Streams processor — updates device registry"
  role             = aws_iam_role.stream_processor.arn
  runtime          = local.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.stream_processor.output_path
  source_code_hash = data.archive_file.stream_processor.output_base64sha256
  timeout          = local.lambda_timeout
  memory_size      = 128

  environment {
    variables = {
      DEVICES_TABLE = aws_dynamodb_table.devices.name
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda_stream.name
  }

  depends_on = [aws_iam_role_policy_attachment.stream_basic]

  tags = {
    Name    = "${var.prefix}-stream-processor"
    Purpose = "Device registry updater"
  }
}

# Connect stream processor to DynamoDB Streams
resource "aws_lambda_event_source_mapping" "incidents_stream" {
  event_source_arn  = aws_dynamodb_table.incidents.stream_arn
  function_name     = aws_lambda_function.stream_processor.arn
  starting_position = "LATEST"
  batch_size        = 10
  bisect_batch_on_function_error = true

  depends_on = [aws_iam_role_policy.stream_processor_inline]
}
