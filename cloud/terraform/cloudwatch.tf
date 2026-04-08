# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
# One log group per service. All are retention-bounded to save cost.

resource "aws_cloudwatch_log_group" "mosquitto" {
  name              = "/${var.prefix}/mosquitto"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-mosquitto-logs" }
}

resource "aws_cloudwatch_log_group" "edge_processor" {
  name              = "/${var.prefix}/edge-processor"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-edge-processor-logs" }
}

resource "aws_cloudwatch_log_group" "fog_processor" {
  name              = "/${var.prefix}/fog-processor"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-fog-processor-logs" }
}

resource "aws_cloudwatch_log_group" "simulator" {
  name              = "/${var.prefix}/simulator"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-simulator-logs" }
}

resource "aws_cloudwatch_log_group" "dashboard" {
  name              = "/${var.prefix}/dashboard"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-dashboard-logs" }
}

resource "aws_cloudwatch_log_group" "lambda_alerts" {
  name              = "/${var.prefix}/lambda-alerts"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-lambda-alerts-logs" }
}

resource "aws_cloudwatch_log_group" "lambda_api" {
  name              = "/${var.prefix}/lambda-api"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-lambda-api-logs" }
}

resource "aws_cloudwatch_log_group" "lambda_stream" {
  name              = "/${var.prefix}/lambda-stream"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-lambda-stream-logs" }
}

resource "aws_cloudwatch_log_group" "iot_rule_errors" {
  name              = "/${var.prefix}/iot-rule-errors"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-iot-rule-errors" }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/${var.prefix}/api-gateway"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-api-gateway-logs" }
}

resource "aws_cloudwatch_log_group" "grafana" {
  count             = var.grafana_enabled ? 1 : 0
  name              = "/${var.prefix}/grafana"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.prefix}-grafana-logs" }
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alert_lambda_errors" {
  alarm_name          = "${var.prefix}-alert-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Alert handler Lambda errors exceeded threshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.alert_handler.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name          = "${var.prefix}-dynamodb-throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "DynamoDB system errors detected"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.incidents.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ECS service alarm — fires if fog-processor task count drops to 0
resource "aws_cloudwatch_metric_alarm" "fog_processor_down" {
  alarm_name          = "${var.prefix}-fog-processor-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Fog processor ECS task count dropped to 0"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.coldchain.name
    ServiceName = aws_ecs_service.fog_processor.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "coldchain" {
  dashboard_name = "${var.prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "metric"
        x = 0
        y = 0
        width = 12
        height = 6
        properties = {
          title   = "Lambda Invocations"
          region  = var.aws_region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.alert_handler.function_name],
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.api_handler.function_name],
          ]
        }
      },
      {
        type       = "metric"
        x = 12 
        y = 0
        width = 12
        height = 6
        properties = {
          title   = "Lambda Errors"
          region  = var.aws_region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.alert_handler.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.api_handler.function_name],
          ]
        }
      },
      {
        type       = "metric"
        x = 0
        y = 6
        width = 12
        height = 6
        properties = {
          title   = "ECS Running Task Count"
          region  = var.aws_region
          period  = 60
          stat    = "Average"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.coldchain.name, "ServiceName", aws_ecs_service.fog_processor.name],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.coldchain.name, "ServiceName", aws_ecs_service.mosquitto.name],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.coldchain.name, "ServiceName", aws_ecs_service.dashboard.name],
          ]
        }
      },
      {
        type       = "log"
        x = 12
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "Recent Alert Events"
          query  = "SOURCE '/${var.prefix}/lambda-alerts' | filter msg = 'incident written to DynamoDB' | fields @timestamp, device_id, event_type, severity | sort @timestamp desc | limit 20"
          region = var.aws_region
        }
      },
    ]
  })
}
