# ── ECS Fargate Cluster ───────────────────────────────────────────────────────
#
# Services deployed (all Fargate, awsvpc networking):
#   1. mosquitto      — Eclipse Mosquitto MQTT broker (internal only)
#   2. edge-processor — EWMA anomaly detection + 5 rules
#   3. fog-processor  — SQLite buffer + AWS IoT Core TLS bridge
#   4. simulator      — IoT device simulator (optional, toggle via var)
#   5. dashboard      — React UI + FastAPI, behind ALB
#   6. grafana        — Grafana OSS (optional)
#
# All services discover each other via AWS Cloud Map DNS:
#   mosquitto.{prefix}.internal:1883
#   dashboard.{prefix}.internal:5001

# ── Local helpers ─────────────────────────────────────────────────────────────

locals {
  mqtt_host = "mosquitto.${var.prefix}.internal"

  # Resolved image URIs — use explicit var first, fall back to ECR :latest
  fog_image       = var.fog_image_uri       != "" ? var.fog_image_uri       : "${aws_ecr_repository.fog_processor.repository_url}:latest"
  edge_image      = var.edge_image_uri      != "" ? var.edge_image_uri      : "${aws_ecr_repository.edge_processor.repository_url}:latest"
  dashboard_image = var.dashboard_image_uri != "" ? var.dashboard_image_uri : "${aws_ecr_repository.dashboard.repository_url}:latest"
  simulator_image = var.simulator_image_uri != "" ? var.simulator_image_uri : "${aws_ecr_repository.simulator.repository_url}:latest"

  # Standard awslogs config factory
  awslogs = { logDriver = "awslogs", options = {
    "awslogs-region"        = var.aws_region
    "awslogs-stream-prefix" = "ecs"
  }}
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "coldchain" {
  name = "${var.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "coldchain" {
  cluster_name       = aws_ecs_cluster.coldchain.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

locals {
  use_provided_vpc = var.vpc_id != "" && length(var.subnet_ids) > 0
}

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
  vpc_id     = local.use_provided_vpc ? var.vpc_id     : data.aws_vpc.default[0].id
  subnet_ids = local.use_provided_vpc ? var.subnet_ids : data.aws_subnets.default[0].ids
}

# Data source to get VPC CIDR for internal security group rules
data "aws_vpc" "selected" {
  id = local.vpc_id
}

# ── ECS Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.prefix}-ecs-tasks-sg"
  description = "Cold-Chain Sentinel ECS tasks"
  vpc_id      = local.vpc_id

  # All outbound — MQTT to IoT Core (8883), HTTPS to ECR/SSM/CW, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MQTT 1883 — allow between ECS tasks in the same SG
  ingress {
    from_port = 1883
    to_port   = 1883
    protocol  = "tcp"
    self      = true
    description = "MQTT between ECS tasks"
  }

  # Dashboard FastAPI — inbound from ALB only
  ingress {
    from_port       = 5001
    to_port         = 5001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Dashboard API from ALB"
  }

  # Fog processor metrics — internal VPC only
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
    description = "Fog metrics (internal)"
  }

  # Grafana UI — restricted to VPC by default (open if needed)
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
    description = "Grafana (internal VPC)"
  }

  tags = { Name = "${var.prefix}-ecs-sg" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. MOSQUITTO — MQTT Broker
# ═══════════════════════════════════════════════════════════════════════════════
# Uses the official eclipse-mosquitto:2.0.18 image.
# Config is written at startup via a shell command so no custom build is needed.

resource "aws_ecs_task_definition" "mosquitto" {
  family                   = "${var.prefix}-mosquitto"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.mosquitto_cpu)
  memory                   = tostring(var.mosquitto_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "mosquitto"
    image     = "eclipse-mosquitto:2.0.18"
    essential = true

    # Write minimal config then start broker
    command = [
      "/bin/sh", "-c",
      "printf 'listener 1883\\nallow_anonymous true\\n' > /mosquitto/config/mosquitto.conf && exec mosquitto -c /mosquitto/config/mosquitto.conf"
    ]

    portMappings = [{ containerPort = 1883, protocol = "tcp" }]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.mosquitto.name
      })
    })

    healthCheck = {
      command     = ["CMD-SHELL", "mosquitto_pub -h localhost -p 1883 -t _health -m ok -q 0 && echo healthy || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])

  tags = { Name = "${var.prefix}-mosquitto" }
}

resource "aws_ecs_service" "mosquitto" {
  name            = "${var.prefix}-mosquitto"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.mosquitto.arn
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

  # Register with Cloud Map so other tasks resolve it as mosquitto.{prefix}.internal
  service_registries {
    registry_arn = aws_service_discovery_service.mosquitto.arn
  }

  deployment_minimum_healthy_percent = 0    # Allow broker restart without blocking
  deployment_maximum_percent         = 100

  enable_execute_command = true

  tags = { Name = "${var.prefix}-mosquitto" }
  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution_managed]
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. EDGE PROCESSOR — EWMA anomaly detection + rules engine
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "edge_processor" {
  family                   = "${var.prefix}-edge-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.edge_cpu)
  memory                   = tostring(var.edge_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "edge-processor"
    image     = local.edge_image
    essential = true

    environment = [
      { name = "MQTT_HOST",                value = local.mqtt_host },
      { name = "MQTT_PORT",                value = "1883" },
      { name = "EDGE_DOWNSAMPLE_N",        value = "10" },
      { name = "EDGE_TEMP_MAX_C",          value = "-15.0" },
      { name = "EDGE_DOOR_OPEN_SECONDS",   value = "300" },
      { name = "EDGE_BATTERY_LOW_V",       value = "11.2" },
      { name = "EDGE_EWMA_ALPHA",          value = "0.1" },
      { name = "EDGE_ANOMALY_ZSCORE",      value = "3.0" },
      { name = "LOG_LEVEL",                value = "INFO" },
    ]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.edge_processor.name
      })
    })
  }])

  tags = { Name = "${var.prefix}-edge-processor" }
}

resource "aws_ecs_service" "edge_processor" {
  name            = "${var.prefix}-edge-processor"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.edge_processor.arn
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

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  tags = { Name = "${var.prefix}-edge-processor" }
  depends_on = [aws_ecs_service.mosquitto, aws_iam_role_policy_attachment.ecs_task_execution_managed]
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. FOG PROCESSOR — SQLite offline buffer + AWS IoT Core TLS bridge
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "fog_processor" {
  family                   = "${var.prefix}-fog-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.ecs_cpu)
  memory                   = tostring(var.ecs_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  ephemeral_storage {
    size_in_gib = 5   # for SQLite offline buffer
  }

  container_definitions = jsonencode([{
    name      = "fog-processor"
    image     = local.fog_image
    essential = true

    portMappings = [{ containerPort = 8080, protocol = "tcp" }]

    environment = [
      { name = "MQTT_HOST",      value = local.mqtt_host },
      { name = "MQTT_PORT",      value = "1883" },
      { name = "FOG_HTTP_PORT",  value = "8080" },
      { name = "BUFFER_DB_PATH", value = "/data/fog_buffer.db" },
      { name = "AWS_IOT_PORT",   value = "8883" },
      { name = "AWS_REGION",     value = var.aws_region },
      { name = "LOG_LEVEL",      value = "INFO" },
    ]

    secrets = [
      { name = "AWS_IOT_ENDPOINT_RAW", valueFrom = aws_ssm_parameter.fog_cert_arn.name },
    ]

    mountPoints = [{
      sourceVolume  = "fog-data"
      containerPath = "/data"
      readOnly      = false
    }]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.fog_processor.name
      })
    })
  }])

  volume {
    name = "fog-data"
    # Ephemeral — buffer is rebuilt on restart. Add EFS here for persistence.
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
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  tags = { Name = "${var.prefix}-fog-processor" }
  depends_on = [aws_ecs_service.mosquitto, aws_iam_role_policy_attachment.ecs_task_execution_managed]
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. SIMULATOR — IoT device simulator (optional)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "simulator" {
  count                    = var.simulator_enabled ? 1 : 0
  family                   = "${var.prefix}-simulator"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.simulator_cpu)
  memory                   = tostring(var.simulator_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "simulator"
    image     = local.simulator_image
    essential = true

    environment = [
      { name = "MQTT_HOST",        value = local.mqtt_host },
      { name = "MQTT_PORT",        value = "1883" },
      { name = "NUM_DEVICES",      value = tostring(var.simulator_num_devices) },
      { name = "PUBLISH_INTERVAL", value = "2.0" },
      { name = "RANDOM_SEED",      value = "42" },
      { name = "CARGO_TYPE",       value = "frozen" },
      { name = "LOG_LEVEL",        value = "INFO" },
    ]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.simulator.name
      })
    })
  }])

  tags = { Name = "${var.prefix}-simulator" }
}

resource "aws_ecs_service" "simulator" {
  count           = var.simulator_enabled ? 1 : 0
  name            = "${var.prefix}-simulator"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.simulator[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"   # Simulator is fault-tolerant, use SPOT for cost
    weight            = 1
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  tags = { Name = "${var.prefix}-simulator" }
  depends_on = [aws_ecs_service.mosquitto, aws_iam_role_policy_attachment.ecs_task_execution_managed]
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. DASHBOARD — React UI + FastAPI WebSocket + Simulator Control
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "dashboard" {
  family                   = "${var.prefix}-dashboard"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.dashboard_cpu)
  memory                   = tostring(var.dashboard_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "dashboard"
    image     = local.dashboard_image
    essential = true

    portMappings = [{ containerPort = 5001, protocol = "tcp" }]

    environment = [
      { name = "MQTT_HOST",    value = local.mqtt_host },
      { name = "MQTT_PORT",    value = "1883" },
      { name = "DASH_PORT",    value = "5001" },
      { name = "DASH_HOST",    value = "0.0.0.0" },
      { name = "LOG_LEVEL",    value = "INFO" },
      { name = "HISTORY_LEN",  value = "60" },
      { name = "MAX_EVENTS",   value = "200" },
      { name = "OFFLINE_SECS", value = "30" },
    ]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.dashboard.name
      })
    })
  }])

  tags = { Name = "${var.prefix}-dashboard" }
}

resource "aws_ecs_service" "dashboard" {
  name            = "${var.prefix}-dashboard"
  cluster         = aws_ecs_cluster.coldchain.id
  task_definition = aws_ecs_task_definition.dashboard.arn
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

  # Register with Cloud Map for internal service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.dashboard.arn
  }

  # Register with ALB target group for public access
  load_balancer {
    target_group_arn = aws_lb_target_group.dashboard.arn
    container_name   = "dashboard"
    container_port   = 5001
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  health_check_grace_period_seconds = 60   # Wait for container to start

  tags = { Name = "${var.prefix}-dashboard" }
  depends_on = [
    aws_ecs_service.mosquitto,
    aws_lb_listener.dashboard_http,
    aws_iam_role_policy_attachment.ecs_task_execution_managed,
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6. GRAFANA — Optional monitoring UI
# ═══════════════════════════════════════════════════════════════════════════════

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

  container_definitions = jsonencode([{
    name      = "grafana"
    image     = "grafana/grafana-oss:latest"
    essential = true

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    environment = [
      { name = "GF_SECURITY_ALLOW_EMBEDDING", value = "true" },
      { name = "GF_AUTH_ANONYMOUS_ENABLED",   value = "false" },
      { name = "GF_LOG_LEVEL",                value = "warn" },
      { name = "GF_INSTALL_PLUGINS",          value = "grafana-timestream-datasource" },
      { name = "AWS_REGION",                  value = var.aws_region },
    ]

    secrets = [{
      name      = "GF_SECURITY_ADMIN_PASSWORD"
      valueFrom = aws_ssm_parameter.grafana_admin_password[0].name
    }]

    logConfiguration = merge(local.awslogs, {
      options = merge(local.awslogs.options, {
        "awslogs-group" = aws_cloudwatch_log_group.grafana[0].name
      })
    })
  }])

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
  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution_managed]
}
