# ── Dashboard ─────────────────────────────────────────────────────────────────

output "dashboard_url" {
  description = "Public URL of the Cold-Chain Sentinel dashboard"
  value       = "http://${aws_lb.dashboard.dns_name}"
}

# ── IoT Core ──────────────────────────────────────────────────────────────────

output "iot_endpoint" {
  description = "AWS IoT Core ATS endpoint"
  value       = "Run: aws iot describe-endpoint --endpoint-type iot:Data-ATS"
}

output "fog_thing_name" {
  description = "IoT Thing name for the fog gateway"
  value       = aws_iot_thing.fog_gateway.name
}

output "fog_cert_id" {
  description = "IoT certificate ID"
  value       = aws_iot_certificate.fog_cert.id
}

output "fog_cert_arn" {
  description = "IoT certificate ARN"
  value       = aws_iot_certificate.fog_cert.arn
}

# ── ECR Repositories ──────────────────────────────────────────────────────────

output "ecr_fog_repo_url" {
  description = "ECR repository URL — fog-processor"
  value       = aws_ecr_repository.fog_processor.repository_url
}

output "ecr_edge_repo_url" {
  description = "ECR repository URL — edge-processor"
  value       = aws_ecr_repository.edge_processor.repository_url
}

output "ecr_simulator_repo_url" {
  description = "ECR repository URL — simulator"
  value       = aws_ecr_repository.simulator.repository_url
}

output "ecr_dashboard_repo_url" {
  description = "ECR repository URL — dashboard"
  value       = aws_ecr_repository.dashboard.repository_url
}

# ── ECS ───────────────────────────────────────────────────────────────────────

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.coldchain.name
}

output "ecs_services" {
  description = "All ECS service names"
  value = {
    mosquitto      = aws_ecs_service.mosquitto.name
    edge_processor = aws_ecs_service.edge_processor.name
    fog_processor  = aws_ecs_service.fog_processor.name
    simulator      = var.simulator_enabled ? aws_ecs_service.simulator[0].name : "(disabled)"
    dashboard      = aws_ecs_service.dashboard.name
  }
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────

output "incidents_table_name" {
  description = "DynamoDB incidents table name"
  value       = aws_dynamodb_table.incidents.name
}

output "devices_table_name" {
  description = "DynamoDB device registry table name"
  value       = aws_dynamodb_table.devices.name
}

# ── SNS ───────────────────────────────────────────────────────────────────────

output "sns_topic_arn" {
  description = "SNS alert topic ARN"
  value       = aws_sns_topic.alerts.arn
}

# ── API Gateway ───────────────────────────────────────────────────────────────

output "api_gateway_url" {
  description = "API Gateway invoke URL (historical incidents REST API)"
  value       = "${aws_apigatewayv2_api.coldchain_api.api_endpoint}/v1"
}

# ── Lambda ────────────────────────────────────────────────────────────────────

output "alert_lambda_arn" {
  description = "Alert handler Lambda ARN"
  value       = aws_lambda_function.alert_handler.arn
}

output "api_lambda_arn" {
  description = "API handler Lambda ARN"
  value       = aws_lambda_function.api_handler.arn
}

# ── Timestream ────────────────────────────────────────────────────────────────

output "timestream_database" {
  description = "Timestream database name (empty if disabled)"
  value       = var.timestream_enabled ? aws_timestreamwrite_database.telemetry[0].database_name : ""
}

output "timestream_table" {
  description = "Timestream table name (empty if disabled)"
  value       = var.timestream_enabled ? aws_timestreamwrite_table.telemetry[0].table_name : ""
}

# ── SSM parameter paths ───────────────────────────────────────────────────────

output "cert_pem_ssm_path" {
  description = "SSM path for IoT certificate PEM"
  value       = aws_ssm_parameter.fog_cert_pem.name
}

output "private_key_ssm_path" {
  description = "SSM path for IoT private key PEM (SecureString)"
  value       = aws_ssm_parameter.fog_private_key.name
}

# ── Service Discovery ─────────────────────────────────────────────────────────

output "cloud_map_namespace" {
  description = "AWS Cloud Map private DNS namespace (internal service discovery)"
  value       = aws_service_discovery_private_dns_namespace.coldchain.name
}

# ── Quick-start summary ───────────────────────────────────────────────────────

output "next_steps" {
  description = "Post-deployment actions"
  value       = <<-EOT
    =====================================================================
    Cold-Chain Sentinel — Infrastructure Provisioned
    =====================================================================

    Dashboard URL  : http://${aws_lb.dashboard.dns_name}
    API Gateway    : ${aws_apigatewayv2_api.coldchain_api.api_endpoint}/v1
    ECS Cluster    : ${aws_ecs_cluster.coldchain.name}
    Cloud Map DNS  : *.${aws_service_discovery_private_dns_namespace.coldchain.name}

    1. Confirm SNS email subscription (check ${aws_sns_topic.alerts.arn})
    2. Dashboard will be live in ~3 minutes (ECS health checks)
    3. Monitor logs:
         aws logs tail /${var.prefix}/dashboard --follow
         aws logs tail /${var.prefix}/fog-processor --follow
    4. Test REST API:
         curl ${aws_apigatewayv2_api.coldchain_api.api_endpoint}/v1/devices
    =====================================================================
  EOT
}
