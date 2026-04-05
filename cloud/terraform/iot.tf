# ── AWS IoT Core: Thing, Certificate, Policy ─────────────────────────────────
#
# Approach (student-friendly but still secure):
# 1. Terraform creates one IoT "Thing" representing the fog gateway.
# 2. Terraform creates an X.509 certificate (AWS-managed — no openssl required).
# 3. The certificate + private key are stored in SSM Parameter Store
#    (SecureString) immediately after creation.
# 4. An IoT Policy allows the fog gateway to:
#    - Connect with its client ID
#    - Publish to aws/coldchain/+/telemetry and aws/coldchain/+/events
#    - Subscribe to $aws/things/{thingName}/shadow/get (optional, for device shadow)
#
# In production, rotate certificates using AWS IoT Device Defender or
# a CI pipeline. Never commit private keys to source control.

# ── IoT Thing ─────────────────────────────────────────────────────────────────

resource "aws_iot_thing" "fog_gateway" {
  name = "${var.prefix}-fog-gateway"

  attributes = {
    type        = "fog-gateway"
    environment = "production"
  }
}

resource "aws_iot_thing_group" "cold_chain" {
  name = "${var.prefix}-devices"

  properties {
    description = "All Cold-Chain Sentinel devices"
  }
}

resource "aws_iot_thing_group_membership" "fog_gateway" {
  thing_name       = aws_iot_thing.fog_gateway.name
  thing_group_name = aws_iot_thing_group.cold_chain.name
}

# ── IoT Certificate ───────────────────────────────────────────────────────────

resource "aws_iot_certificate" "fog_cert" {
  active = true
}

# ── Store certificate material in SSM ────────────────────────────────────────

resource "aws_ssm_parameter" "fog_cert_pem" {
  name        = "/${var.prefix}/iot/cert-pem"
  description = "IoT certificate PEM for fog gateway"
  type        = "SecureString"
  value       = aws_iot_certificate.fog_cert.certificate_pem
}

resource "aws_ssm_parameter" "fog_private_key" {
  name        = "/${var.prefix}/iot/private-key"
  description = "IoT private key PEM for fog gateway (SENSITIVE)"
  type        = "SecureString"
  value       = aws_iot_certificate.fog_cert.private_key
}

resource "aws_ssm_parameter" "fog_cert_arn" {
  name        = "/${var.prefix}/iot/cert-arn"
  description = "IoT certificate ARN for fog gateway"
  type        = "String"
  value       = aws_iot_certificate.fog_cert.arn
}

# ── IoT Policy ────────────────────────────────────────────────────────────────

resource "aws_iot_policy" "fog_gateway_policy" {
  name = "${var.prefix}-fog-gateway-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Allow connect with the registered client ID only
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${local.region}:${local.account_id}:client/fog-gateway-*"
      },
      {
        # Allow publish to cold-chain topics only
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = [
          "arn:aws:iot:${local.region}:${local.account_id}:topic/aws/coldchain/*/telemetry",
          "arn:aws:iot:${local.region}:${local.account_id}:topic/aws/coldchain/*/events",
        ]
      },
      {
        # Allow receive (needed for QoS 1 PUBACK)
        Effect   = "Allow"
        Action   = "iot:Receive"
        Resource = [
          "arn:aws:iot:${local.region}:${local.account_id}:topic/aws/coldchain/*/telemetry",
          "arn:aws:iot:${local.region}:${local.account_id}:topic/aws/coldchain/*/events",
        ]
      },
    ]
  })
}

# ── Attach certificate to thing and policy ────────────────────────────────────

resource "aws_iot_thing_principal_attachment" "fog_gateway" {
  thing     = aws_iot_thing.fog_gateway.name
  principal = aws_iot_certificate.fog_cert.arn
}

resource "aws_iot_policy_attachment" "fog_gateway" {
  policy = aws_iot_policy.fog_gateway_policy.name
  target = aws_iot_certificate.fog_cert.arn
}

# ── IoT Topic Rules ───────────────────────────────────────────────────────────
#
# Rule 1: Telemetry → Timestream (if enabled) + CloudWatch Logs
# Rule 2: Events    → DynamoDB (via Lambda) + SNS

# Rule: route events to alert Lambda
resource "aws_iot_topic_rule" "events_rule" {
  name        = "${replace(var.prefix, "-", "_")}_events_rule"
  description = "Route cold-chain events to alert Lambda"
  enabled     = true
  sql         = "SELECT * FROM 'aws/coldchain/+/events'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.alert_handler.arn
  }

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_rule_errors.name
      role_arn       = aws_iam_role.iot_rule_role.arn
    }
  }
}

# Rule: route telemetry to Timestream (conditional on var.timestream_enabled)
resource "aws_iot_topic_rule" "telemetry_rule" {
  name        = "${replace(var.prefix, "-", "_")}_telemetry_rule"
  description = "Route cold-chain telemetry to Timestream"
  enabled     = var.timestream_enabled
  sql         = "SELECT * FROM 'aws/coldchain/+/telemetry'"
  sql_version = "2016-03-23"

  dynamic "timestream" {
    for_each = var.timestream_enabled ? [1] : []
    content {
      role_arn    = aws_iam_role.iot_rule_role.arn
      database_name = aws_timestreamwrite_database.telemetry[0].database_name
      table_name    = aws_timestreamwrite_table.telemetry[0].table_name

      dimension {
        name  = "device_id"
        value = "$${device_id}"
      }

      timestamp {
        unit  = "SECONDS"
        value = "$${ts}"
      }
    }
  }

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_rule_errors.name
      role_arn       = aws_iam_role.iot_rule_role.arn
    }
  }
}

# Allow IoT Core to invoke the alert Lambda
resource "aws_lambda_permission" "iot_invoke_alert" {
  statement_id  = "AllowIoTCoreInvokeAlert"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert_handler.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.events_rule.arn
}
