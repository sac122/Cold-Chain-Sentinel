"""
Data contracts for Cold-Chain Sentinel.

JSON schemas and Pydantic v2 models for telemetry and events.

Telemetry schema (raw + processed):
  device_id  : str        – unique device identifier (e.g. "truck-042")
  ts         : float      – Unix epoch (seconds, float for sub-second)
  gps        : GPSCoord   – lat/lon
  temp_c     : float      – temperature in Celsius
  humidity   : float      – relative humidity 0–100 %
  door_open  : bool       – cargo door state
  battery_v  : float      – supply voltage (V)
  vibration  : float      – RMS vibration magnitude (m/s²)
  # Edge-computed (None in raw messages)
  anomaly_score : float|None  – EWMA z-score vs rolling σ
  ewma_temp     : float|None  – exponentially-weighted moving-average temperature
  edge_processed: bool        – True once edge layer has annotated the message

Event schema:
  device_id     : str
  ts            : float
  event_id      : str       – UUIDv4 for deduplication
  event_type    : EventType
  severity      : EventSeverity
  reason        : str       – human-readable description
  telemetry     : TelemetryPayload – snapshot at event time
  anomaly_score : float|None
  duration_seconds : float|None  – how long condition persisted
  prev_gps      : GPSCoord|None  – for GPS-jump events
"""
from __future__ import annotations

import time
import uuid
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

class GPSCoord(BaseModel):
    lat: float = Field(..., ge=-90.0, le=90.0)
    lon: float = Field(..., ge=-180.0, le=180.0)


# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

class TelemetryPayload(BaseModel):
    """
    Published to: coldchain/{device_id}/raw          (simulator → edge)
    Published to: coldchain/{device_id}/telemetry    (edge → fog, downsampled)
    Forwarded to: aws/coldchain/{device_id}/telemetry (fog → AWS IoT Core)
    """
    device_id: str
    ts: float = Field(default_factory=time.time)
    gps: GPSCoord
    temp_c: float = Field(..., description="Cargo temperature in °C")
    humidity: float = Field(..., ge=0.0, le=100.0)
    door_open: bool = Field(default=False)
    battery_v: float = Field(..., ge=0.0, le=15.0, description="Supply voltage V")
    vibration: float = Field(..., ge=0.0, description="RMS vibration m/s²")
    # Edge-computed fields — None in raw simulator messages
    anomaly_score: Optional[float] = Field(
        default=None,
        description="EWMA z-score; magnitude > 3.0 is flagged"
    )
    ewma_temp: Optional[float] = Field(
        default=None,
        description="Exponentially-weighted moving-average of temp_c"
    )
    edge_processed: bool = Field(default=False)
    seq: int = Field(default=0, description="Per-device sequence counter")

    def to_aws_dict(self) -> dict:
        """Return a flat dict suitable for Timestream / DynamoDB write."""
        d = self.model_dump()
        d["lat"] = d.pop("gps")["lat"]
        d["lon"] = d["gps"]["lon"] if "gps" in d else d.get("lon")
        # model_dump already flattened gps above; fix:
        raw = self.model_dump()
        return {
            "device_id": raw["device_id"],
            "ts": str(raw["ts"]),
            "lat": str(raw["gps"]["lat"]),
            "lon": str(raw["gps"]["lon"]),
            "temp_c": str(raw["temp_c"]),
            "humidity": str(raw["humidity"]),
            "door_open": str(raw["door_open"]).lower(),
            "battery_v": str(raw["battery_v"]),
            "vibration": str(raw["vibration"]),
            "anomaly_score": str(raw["anomaly_score"]) if raw["anomaly_score"] is not None else "",
            "ewma_temp": str(raw["ewma_temp"]) if raw["ewma_temp"] is not None else "",
            "seq": str(raw["seq"]),
        }


# ---------------------------------------------------------------------------
# Events / Incidents
# ---------------------------------------------------------------------------

class EventSeverity(str, Enum):
    INFO = "INFO"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"


class EventType(str, Enum):
    TEMP_EXCURSION = "TEMP_EXCURSION"
    DOOR_OPEN_TOO_LONG = "DOOR_OPEN_TOO_LONG"
    BATTERY_LOW = "BATTERY_LOW"
    SENSOR_STUCK = "SENSOR_STUCK"
    ANOMALY = "ANOMALY"
    GPS_JUMP = "GPS_JUMP"
    COMPRESSOR_FAIL = "COMPRESSOR_FAIL"


class EventPayload(BaseModel):
    """
    Published to: coldchain/{device_id}/events       (edge → fog)
    Forwarded to: aws/coldchain/{device_id}/events   (fog → AWS IoT Core)
    """
    device_id: str
    ts: float = Field(default_factory=time.time)
    event_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    event_type: EventType
    severity: EventSeverity
    reason: str
    telemetry: TelemetryPayload
    anomaly_score: Optional[float] = None
    duration_seconds: Optional[float] = Field(
        default=None,
        description="Duration of the condition triggering this event"
    )
    prev_gps: Optional[GPSCoord] = Field(
        default=None,
        description="Previous GPS position (for GPS-jump events)"
    )

    def ttl_epoch(self, retain_days: int = 90) -> int:
        """Return Unix epoch for DynamoDB TTL (ts + retain_days)."""
        return int(self.ts) + retain_days * 86400

    def to_dynamodb_item(self) -> dict:
        """Return a DynamoDB-ready item dict (string keys, typed values)."""
        return {
            "device_id":       {"S": self.device_id},
            "ts_event_id":     {"S": f"{self.ts:.6f}#{self.event_id}"},
            "ts":              {"N": str(self.ts)},
            "event_id":        {"S": self.event_id},
            "event_type":      {"S": self.event_type.value},
            "severity":        {"S": self.severity.value},
            "reason":          {"S": self.reason},
            "anomaly_score":   {"N": str(self.anomaly_score)} if self.anomaly_score is not None else {"NULL": True},
            "duration_seconds":{"N": str(self.duration_seconds)} if self.duration_seconds is not None else {"NULL": True},
            "telemetry_json":  {"S": self.telemetry.model_dump_json()},
            "ttl":             {"N": str(self.ttl_epoch())},
        }
