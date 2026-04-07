# ── AWS Cloud Map — Private DNS for ECS service-to-service communication ─────
#
# All ECS services find each other via DNS:
#   mosquitto  →  mosquitto.{prefix}.internal:1883
#   dashboard  →  dashboard.{prefix}.internal:5001
#
# Why Cloud Map instead of hardcoded IPs?
#   - Fargate tasks get ephemeral IPs; DNS handles rotation automatically
#   - Zero-code change: services still use MQTT_HOST=mosquitto (etc.)

resource "aws_service_discovery_private_dns_namespace" "coldchain" {
  name        = "${var.prefix}.internal"
  description = "Cold-Chain Sentinel private DNS namespace for ECS"
  vpc         = local.vpc_id

  tags = { Name = "${var.prefix}-dns-namespace" }
}

# ── Mosquitto (MQTT broker) ───────────────────────────────────────────────────

resource "aws_service_discovery_service" "mosquitto" {
  name = "mosquitto"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.coldchain.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ── Dashboard ─────────────────────────────────────────────────────────────────

resource "aws_service_discovery_service" "dashboard" {
  name = "dashboard"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.coldchain.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}
