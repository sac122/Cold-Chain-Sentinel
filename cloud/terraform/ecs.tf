# ── ECS Fargate Cluster ───────────────────────────────────────────────────────
#
# Hosts:
# 1. fog-processor service  — bridges local MQTT to AWS IoT Core
# 2. grafana service (opt)  — Grafana OSS for dashboards
#
# Why ECS over EKS?
# - Project scale: 1-3 services; Kubernetes overhead is unjustified
# - ECS Fargate: serverless — no EC2 to manage, pay-per-second
# - ECS is sufficient for the fog gateway pattern (1 task replicated as needed)
# - EKS adds ~$0.10/hr control-plane cost + node management complexity

resource "aws_ecs_cluster" "coldchain" {
  name = "${var.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.prefix}-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "coldchain" {
  cluster_name       = aws_ecs_cluster.coldchain.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── Networking (use provided subnets or create simple ones) ──────────────────

locals {
  use_provided_vpc = var.vpc_id != "" && length(var.subnet_ids) > 0
}

# Default VPC data source (used when no VPC is provided)
data "aws_vpc" "default" {
  count   = local.use_provided_vpc ? 0 : 1
  default = true
}

data "aws_subnets" "default" {
  count = local.use_provided_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

locals {
  vpc_id     = local.use_provided_vpc ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_ids = local.use_provided_vpc ? var.subnet_ids : data.aws_subnets.default[0].ids
}

# Security group for ECS tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.prefix}-ecs-tasks-sg"
  description = "Cold-Chain Sentinel ECS tasks"
  vpc_id      = local.vpc_id

  # Outbound: allow all (needed for MQTT to AWS IoT Core + HTTPS to ECR)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound: Fog processor HTTP metrics
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  # Inbound: Grafana UI
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # restrict to office IPs in production
  }

  tags = { Name = "${var.prefix}-ecs-sg" }
}

# ── Fog Processor Task Definition ─────────────────────────────────────────────

resource "aws_ecs_task_definition" "fog_processor" {
  family                   = "${var.prefix}-fog-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.ecs_cpu)
  memory                   = tostring(var.ecs_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  # Ephemeral storage for SQLite buffer (not persisted across task restarts)
  ephemeral_storage {
    size_in_gib = 5
  }

  container_definitions = jsonencode([
    {
      name      = "fog-processor"
      image     = var.fog_image_uri != "" ? var.fog_image_uri : "${aws_ecr_repository.fog_processor.repository_url}:latest"
      essential = true

      portMappings = [{
        containerPort = 8080
        protocol      = "tcp"
      }]

      environment = [
        { name = "MQTT_HOST",             value = "mosquitto" },
        { name = "MQTT_PORT",             value = "1883" },
        { name = "FOG_HTTP_PORT",         value = "8080" },
        { name = "BUFFER_DB_PATH",        value = "/data/fog_buffer.db" },
        { name = "AWS_IOT_PORT",          value = "8883" },
        { name = "AWS_REGION",            value = var.aws_region },
        { name = "LOG_LEVEL",             value = "INFO" },
      ]

      # Certificate paths injected via SSM secrets at task start
      secrets = [
        {
          name      = "AWS_IOT_ENDPOINT_RAW"
          valueFrom = aws_ssm_parameter.fog_cert_arn.name
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.fog_processor.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "fog"
        }
      }

      mountPoints = [{
        sourceVolume  = "fog-data"
        containerPath = "/data"
        readOnly      = false
      }]
    }
  ])

  volume {
    name = "fog-data"
    # EFS mount point can be added here for persistent buffer across task restarts
    # For now, uses ephemeral storage (buffer is rebuilt on restart)
  }

  tags = { Name = "${var.prefix}-fog-processor" }
}

resource "aws_ecs_service" "fog_processor" {
  name            = "${var.prefix}-fog-processor"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.fog_processor.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true   # needed when using public subnets without NAT
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  enable_execute_command = true   # for debugging via `aws ecs execute-command`

  tags = { Name = "${var.prefix}-fog-processor" }

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution_managed]
}

# ── Grafana OSS Task (optional) ───────────────────────────────────────────────

resource "aws_ssm_parameter" "grafana_admin_password" {
  count       = var.grafana_enabled ? 1 : 0
  name        = "/${var.prefix}/grafana/admin-password"
  description = "Grafana admin password"
  type        = "SecureString"
  value       = var.grafana_admin_password
}

resource "aws_ecs_task_definition" "grafana" {
  count                    = var.grafana_enabled ? 1 : 0
  family                   = "${var.prefix}-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.grafana_cpu)
  memory                   = tostring(var.grafana_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "grafana/grafana-oss:latest"
      essential = true

      portMappings = [{
        containerPort = 3000
        protocol      = "tcp"
      }]

      environment = [
        { name = "GF_SECURITY_ALLOW_EMBEDDING",  value = "true" },
        { name = "GF_AUTH_ANONYMOUS_ENABLED",    value = "false" },
        { name = "GF_LOG_LEVEL",                 value = "warn" },
        { name = "GF_INSTALL_PLUGINS",
          value = "grafana-timestream-datasource" },
        { name = "AWS_REGION",                   value = var.aws_region },
      ]

      secrets = [
        {
          name      = "GF_SECURITY_ADMIN_PASSWORD"
          valueFrom = aws_ssm_parameter.grafana_admin_password[0].name
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.grafana[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])

  tags = { Name = "${var.prefix}-grafana" }
}

resource "aws_ecs_service" "grafana" {
  count           = var.grafana_enabled ? 1 : 0
  name            = "${var.prefix}-grafana"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.grafana[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  tags = { Name = "${var.prefix}-grafana" }
}
