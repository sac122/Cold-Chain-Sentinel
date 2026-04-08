# ── DynamoDB Tables ───────────────────────────────────────────────────────────
#
# incidents table
# ───────────────
# PK:  device_id   (String) — partition by device
# SK:  ts_event_id (String) — sort key = "{unix_ts:.6f}#{uuid}" for ordering + uniqueness
# TTL: ttl         (Number) — auto-delete after INCIDENT_TTL_DAYS days
#
# GSI: severity-ts-index
#   PK: severity (String)
#   SK: ts (Number)  — allows "give me all CRITICAL events in last 1 hour"
#
# Tradeoff vs Timestream for incidents
# ──────────────────────────────────────
# DynamoDB is chosen for incidents/events because:
#   - Events are low-volume (few per device per hour at most)
#   - We need flexible querying by severity, device_id, event_type
#   - DynamoDB GSIs handle these patterns well
#   - No time-series aggregation needed — just look up individual events
#
# Timestream is used for telemetry because:
#   - Telemetry is high-volume (1 message/2s per device × hundreds of devices)
#   - We need time-range queries and aggregations (AVG temp over last hour)
#   - Timestream auto-partitions by time and compresses efficiently
#   - It would be expensive to store dense telemetry in DynamoDB

# ── Incidents ─────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "incidents" {
  name           = "${var.prefix}-incidents"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "device_id"
  range_key      = "ts_event_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "ts_event_id"
    type = "S"
  }

  attribute {
    name = "severity"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "N"
  }

  # TTL — auto-expire incidents after N days
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # GSI for querying by severity + timestamp
  global_secondary_index {
    name               = "severity-ts-index"
    hash_key           = "severity"
    range_key          = "ts"
    projection_type    = "ALL"
  }

  # Enable streams so stream_processor Lambda can update device registry
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "${var.prefix}-incidents"
    Purpose = "Cold-chain incident/event records"
  }
}

# ── Device Registry ──────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "devices" {
  name         = "${var.prefix}-devices"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "${var.prefix}-devices"
    Purpose = "Device registry - last known state per device"
  }
}
