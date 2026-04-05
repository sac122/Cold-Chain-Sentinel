variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Resource name prefix (e.g. 'coldchain-prod')"
  type        = string
  default     = "coldchain"
}

variable "alert_email" {
  description = "Email address to receive SNS cold-chain alerts"
  type        = string
}

variable "timestream_enabled" {
  description = "Create a Timestream database/table for telemetry storage"
  type        = bool
  default     = true
}

variable "grafana_enabled" {
  description = "Deploy Grafana OSS to ECS Fargate"
  type        = bool
  default     = true
}

variable "ecs_cpu" {
  description = "ECS Fargate task CPU units for fog processor"
  type        = number
  default     = 256
}

variable "ecs_memory" {
  description = "ECS Fargate task memory (MiB) for fog processor"
  type        = number
  default     = 512
}

variable "grafana_cpu" {
  description = "ECS Fargate task CPU units for Grafana"
  type        = number
  default     = 512
}

variable "grafana_memory" {
  description = "ECS Fargate task memory (MiB) for Grafana"
  type        = number
  default     = 1024
}

variable "vpc_id" {
  description = "VPC ID for ECS tasks and ALB (leave empty to create a new VPC)"
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS tasks (at least 2 for ALB)"
  type        = list(string)
  default     = []
}

variable "incident_ttl_days" {
  description = "DynamoDB TTL for incident records (days)"
  type        = number
  default     = 90
}

variable "log_retention_days" {
  description = "CloudWatch log group retention (days)"
  type        = number
  default     = 30
}

variable "fog_image_uri" {
  description = "Full ECR image URI for the fog-processor container"
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password (stored in SSM)"
  type        = string
  sensitive   = true
  default     = "ChangeMeNow123!"
}

# ── Timestream retention ──────────────────────────────────────────────────────
variable "timestream_memory_hours" {
  description = "Timestream memory store retention (hours)"
  type        = number
  default     = 24
}

variable "timestream_magnetic_days" {
  description = "Timestream magnetic store retention (days)"
  type        = number
  default     = 90
}
