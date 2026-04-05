# ── IAM Roles and Policies ────────────────────────────────────────────────────
#
# Principle of least privilege:
# - Lambda functions get only the DynamoDB tables and SNS topic they need.
# - ECS task role gets only SSM parameter reads (for cert retrieval).
# - IoT rule role gets only Timestream write + Lambda invoke + CW Logs.
# - No wildcard resource ARNs except where unavoidable.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "iot_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
  }
}

# ── Alert Handler Lambda Role ─────────────────────────────────────────────────

resource "aws_iam_role" "alert_handler" {
  name               = "${var.prefix}-alert-handler-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "alert_basic" {
  role       = aws_iam_role.alert_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "alert_handler_inline" {
  name  = "alert-handler-permissions"
  role  = aws_iam_role.alert_handler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
    ]
  })
}

# ── API Handler Lambda Role ───────────────────────────────────────────────────

resource "aws_iam_role" "api_handler" {
  name               = "${var.prefix}-api-handler-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "api_basic" {
  role       = aws_iam_role.api_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "api_handler_inline" {
  name  = "api-handler-permissions"
  role  = aws_iam_role.api_handler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:Scan", "dynamodb:GetItem"]
        Resource = [
          aws_dynamodb_table.incidents.arn,
          "${aws_dynamodb_table.incidents.arn}/index/*",
          aws_dynamodb_table.devices.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["timestream:Select", "timestream:DescribeTable", "timestream:ListMeasures"]
        Resource = var.timestream_enabled ? [
          aws_timestreamwrite_table.telemetry[0].arn,
        ] : ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["timestream:DescribeEndpoints"]
        Resource = "*"
      },
    ]
  })
}

# ── Stream Processor Lambda Role ──────────────────────────────────────────────

resource "aws_iam_role" "stream_processor" {
  name               = "${var.prefix}-stream-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "stream_basic" {
  role       = aws_iam_role.stream_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "stream_processor_inline" {
  name  = "stream-processor-permissions"
  role  = aws_iam_role.stream_processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:UpdateItem", "dynamodb:PutItem", "dynamodb:GetItem",
          "dynamodb:GetRecords", "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream", "dynamodb:ListStreams",
        ]
        Resource = [
          aws_dynamodb_table.devices.arn,
          aws_dynamodb_table.incidents.arn,
          aws_dynamodb_table.incidents.stream_arn,
        ]
      },
    ]
  })
}

# ── ECS Task Execution Role ───────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_execution_ecr" {
  name  = "ecs-ecr-ssm"
  role  = aws_iam_role.ecs_task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"   # needed for SecureString SSM parameters
      },
    ]
  })
}

# ── ECS Task Role (runtime permissions) ──────────────────────────────────────

resource "aws_iam_role" "ecs_task" {
  name               = "${var.prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "ecs_task_inline" {
  name  = "ecs-task-permissions"
  role  = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.prefix}/iot/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.fog_processor.arn}:*"
      },
    ]
  })
}

# ── IoT Rule Role ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "iot_rule_role" {
  name               = "${var.prefix}-iot-rule-role"
  assume_role_policy = data.aws_iam_policy_document.iot_assume.json
}

resource "aws_iam_role_policy" "iot_rule_inline" {
  name  = "iot-rule-permissions"
  role  = aws_iam_role.iot_rule_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.alert_handler.arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "timestream:WriteRecords",
          "timestream:DescribeEndpoints",
        ]
        Resource = var.timestream_enabled ? [
          aws_timestreamwrite_table.telemetry[0].arn
        ] : ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.iot_rule_errors.arn}:*"
      },
    ]
  })
}
