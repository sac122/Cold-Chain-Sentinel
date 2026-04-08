# ── API Gateway v2 (HTTP API) ─────────────────────────────────────────────────
#
# HTTP API is chosen over REST API because:
# - Lower cost (~70% cheaper)
# - Lower latency
# - Simpler Terraform resource model
# - Sufficient for these simple CRUD endpoints

resource "aws_apigatewayv2_api" "coldchain_api" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
  description   = "Cold-Chain Sentinel REST API"

  cors_configuration {
    allow_headers = ["Content-Type", "Authorization"]
    allow_methods = ["GET", "OPTIONS"]
    allow_origins = ["*"]
    max_age       = 300
  }

  tags = {
    Name = "${var.prefix}-api"
  }
}

resource "aws_apigatewayv2_stage" "v1" {
  api_id      = aws_apigatewayv2_api.coldchain_api.id
  name        = "v1"
  auto_deploy = true

  access_log_settings {
  destination_arn = aws_cloudwatch_log_group.api_gateway.arn

  format = jsonencode({
    requestId      = "$context.requestId"
    ip             = "$context.identity.sourceIp"
    requestTime    = "$context.requestTime"
    httpMethod     = "$context.httpMethod"
    routeKey       = "$context.routeKey"
    status         = "$context.status"
    protocol       = "$context.protocol"
    responseLength = "$context.responseLength"
  })
}

  default_route_settings {
    throttling_burst_limit  = 100
    throttling_rate_limit   = 50
  }
}

# ── Lambda integration ────────────────────────────────────────────────────────

resource "aws_apigatewayv2_integration" "api_lambda" {
  api_id             = aws_apigatewayv2_api.coldchain_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.api_handler.invoke_arn
  payload_format_version = "2.0"
}

# ── Routes ────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_route" "list_devices" {
  api_id    = aws_apigatewayv2_api.coldchain_api.id
  route_key = "GET /devices"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda.id}"
}

resource "aws_apigatewayv2_route" "list_incidents" {
  api_id    = aws_apigatewayv2_api.coldchain_api.id
  route_key = "GET /incidents"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda.id}"
}

resource "aws_apigatewayv2_route" "device_summary" {
  api_id    = aws_apigatewayv2_api.coldchain_api.id
  route_key = "GET /devices/{device_id}/summary"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda.id}"
}

# ── Permission for API Gateway to invoke Lambda ───────────────────────────────

resource "aws_lambda_permission" "apigw_invoke_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.coldchain_api.execution_arn}/*/*"
}
