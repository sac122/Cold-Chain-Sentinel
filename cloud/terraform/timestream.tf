# ── Amazon Timestream (optional) ─────────────────────────────────────────────
#
# Used to store dense telemetry time-series.
# Controlled by var.timestream_enabled (default: true).
#
# Why Timestream over DynamoDB for telemetry?
# ────────────────────────────────────────────
# Telemetry arrives at ~1 msg/2s per device. With 100 devices that is
# 50 writes/second — perfectly feasible in DynamoDB, but Timestream is
# purpose-built for this pattern:
#   - Automatic time-partitioning (no need to design sort key schemes)
#   - Built-in time-series SQL with functions like INTERPOLATE, BIN, AVG
#   - Tiered storage: hot data in memory, cold data on SSD (magnetic)
#   - ~90% cheaper than DynamoDB for dense time-series at scale
#   - Native Grafana data source plugin
#
# Downside vs DynamoDB:
#   - No conditional writes / transactions
#   - Cannot easily look up a single record by ID
#   - Minimum billing unit is 1 KB per record
#   - Slightly higher Lambda SDK complexity

resource "aws_timestreamwrite_database" "telemetry" {
  count         = var.timestream_enabled ? 1 : 0
  database_name = "${var.prefix}-telemetry"

  tags = {
    Name    = "${var.prefix}-telemetry"
    Purpose = "Cold-chain telemetry time-series"
  }
}

resource "aws_timestreamwrite_table" "telemetry" {
  count         = var.timestream_enabled ? 1 : 0
  database_name = aws_timestreamwrite_database.telemetry[0].database_name
  table_name    = "device_telemetry"

  retention_properties {
    memory_store_retention_period_in_hours  = var.timestream_memory_hours
    magnetic_store_retention_period_in_days = var.timestream_magnetic_days
  }

  # Partition key on device_id for efficient per-device queries
  schema {
    composite_partition_key {
      enforcement_in_record = "OPTIONAL"
      name                  = "device_id"
      type                  = "DIMENSION"
    }
  }

  magnetic_store_write_properties {
    enable_magnetic_store_writes = true
  }

  tags = {
    Name    = "${var.prefix}-device-telemetry"
    Purpose = "Telemetry measurements"
  }
}
