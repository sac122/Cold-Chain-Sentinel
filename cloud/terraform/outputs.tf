output "iot_endpoint" {
  description = "AWS IoT Core ATS endpoint (use this in fog-processor config)"
  value       = "Use: aws iot describe-endpoint --endpoint-type iot:Data-ATS"
}

output "fog_thing_name" {
  description = "IoT Thing name for the fog gateway"
  value       = aws_iot_thing.fog_gateway.name
}

output "fog_cert_id" {
  description = "IoT certificate ID (download cert/key from console or Terraform state)"
  value       = aws_iot_certificate.fog_cert.id
}

output "fog_cert_arn" {
  description = "IoT certificate ARN"
  value       = aws_iot_certificate.fog_cert.arn
}

output "incidents_table_name" {
  description = "DynamoDB incidents table name"
  value       = aws_dynamodb_table.incidents.name
}

output "devices_table_name" {
  description = "DynamoDB device registry table name"
  value       = aws_dynamodb_table.devices.name
}

output "sns_topic_arn" {
  description = "SNS alert topic ARN"
  value       = aws_sns_topic.alerts.arn
}

output "api_gateway_url" {
  description = "API Gateway invoke URL"
  value       = "${aws_apigatewayv2_api.coldchain_api.api_endpoint}/v1"
}

output "alert_lambda_arn" {
  description = "Alert handler Lambda ARN"
  value       = aws_lambda_function.alert_handler.arn
}

output "api_lambda_arn" {
  description = "API handler Lambda ARN"
  value       = aws_lambda_function.api_handler.arn
}

output "ecr_fog_repo_url" {
  description = "ECR repository URL for fog-processor image"
  value       = aws_ecr_repository.fog_processor.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.coldchain.name
}

output "timestream_database" {
  description = "Timestream database name (empty if disabled)"
  value       = var.timestream_enabled ? aws_timestreamwrite_database.telemetry[0].database_name : ""
}

output "timestream_table" {
  description = "Timestream table name (empty if disabled)"
  value       = var.timestream_enabled ? aws_timestreamwrite_table.telemetry[0].table_name : ""
}

output "grafana_task_definition" {
  description = "Grafana ECS task definition ARN (empty if disabled)"
  value       = var.grafana_enabled ? aws_ecs_task_definition.grafana[0].arn : ""
}

output "cert_pem_ssm_path" {
  description = "SSM path where certificate PEM is stored"
  value       = aws_ssm_parameter.fog_cert_pem.name
}

output "private_key_ssm_path" {
  description = "SSM path where private key PEM is stored (SecureString)"
  value       = aws_ssm_parameter.fog_private_key.name
}

output "next_steps" {
  description = "Next steps after apply"
  value       = <<-EOT
    =====================================================================
    Cold-Chain Sentinel — Infrastructure Provisioned
    =====================================================================

    1. Retrieve IoT certificates:
       aws ssm get-parameter --name /${var.prefix}/iot/cert-pem --with-decryption
       aws ssm get-parameter --name /${var.prefix}/iot/private-key --with-decryption

    2. Get IoT Core endpoint:
       aws iot describe-endpoint --endpoint-type iot:Data-ATS

    3. Build and push fog-processor image:
       make push-fog AWS_REGION=${var.aws_region}

    4. Confirm SNS subscription:
       Check your email (${var.alert_email}) for confirmation link.

    5. Update ECS service with new image:
       make deploy-ecs AWS_REGION=${var.aws_region}

    6. Monitor in CloudWatch:
       /coldchain/fog-processor
       /coldchain/lambda-alerts
       /coldchain/lambda-api
    =====================================================================
  EOT
}
