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

# ── Feature flags ─────────────────────────────────────────────────────────────

variable "timestream_enabled" {
  description = "Create a Timestream database/table for telemetry storage"
  type        = bool
  default     = true
}

variable "grafana_enabled" {
  description = "Deploy Grafana OSS to ECS Fargate"
  type        = bool
  default     = false   # Disabled by default — dashboard covers live monitoring
}

variable "simulator_enabled" {
  description = "Deploy the IoT simulator on ECS (useful for cloud demo/testing)"
  type        = bool
  default     = true
}

# ── ECS resource sizing ───────────────────────────────────────────────────────

variable "ecs_cpu" {
  description = "ECS Fargate task CPU units for fog-processor"
  type        = number
  default     = 256
}

variable "ecs_memory" {
  description = "ECS Fargate task memory (MiB) for fog-processor"
  type        = number
  default     = 512
}

variable "edge_cpu" {
  description = "ECS Fargate task CPU units for edge-processor"
  type        = number
  default     = 256
}

variable "edge_memory" {
  description = "ECS Fargate task memory (MiB) for edge-processor"
  type        = number
  default     = 512
}

variable "mosquitto_cpu" {
  description = "ECS Fargate task CPU units for Mosquitto broker"
  type        = number
  default     = 256
}

variable "mosquitto_memory" {
  description = "ECS Fargate task memory (MiB) for Mosquitto broker"
  type        = number
  default     = 512
}

variable "dashboard_cpu" {
  description = "ECS Fargate task CPU units for the React dashboard"
  type        = number
  default     = 512
}

variable "dashboard_memory" {
  description = "ECS Fargate task memory (MiB) for the React dashboard"
  type        = number
  default     = 1024
}

variable "simulator_cpu" {
  description = "ECS Fargate task CPU units for the IoT simulator"
  type        = number
  default     = 512
}

variable "simulator_memory" {
  description = "ECS Fargate task memory (MiB) for the IoT simulator"
  type        = number
  default     = 1024
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

variable "simulator_num_devices" {
  description = "Number of simulated IoT devices"
  type        = number
  default     = 10
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID for ECS tasks and ALB (leave empty to use the default VPC)"
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS tasks and ALB (at least 2 for ALB)"
  type        = list(string)
  default     = []
}

# ── Retention / TTL ───────────────────────────────────────────────────────────

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

# ── Image URIs (override after first Terraform apply + ECR push) ──────────────

variable "fog_image_uri" {
  description = "Full ECR URI for fog-processor image (auto-detected if empty)"
  type        = string
  default     = ""
}

variable "edge_image_uri" {
  description = "Full ECR URI for edge-processor image (auto-detected if empty)"
  type        = string
  default     = ""
}

variable "dashboard_image_uri" {
  description = "Full ECR URI for dashboard image (auto-detected if empty)"
  type        = string
  default     = ""
}

variable "simulator_image_uri" {
  description = "Full ECR URI for simulator image (auto-detected if empty)"
  type        = string
  default     = ""
}

# ── Secrets ───────────────────────────────────────────────────────────────────

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
