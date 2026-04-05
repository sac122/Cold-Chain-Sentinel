"""
Simulator configuration — driven entirely by environment variables
so the same image runs locally (docker compose) and on CI/AWS.
"""
from __future__ import annotations

import os
import sys

# Add project root to path so `shared` is importable inside Docker
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shared.utils import env_int, env_float, env_bool


class SimulatorConfig:
    # ── MQTT broker ──────────────────────────────────────────────
    MQTT_HOST: str         = os.getenv("MQTT_HOST", "localhost")
    MQTT_PORT: int         = env_int("MQTT_PORT", 1883)
    MQTT_USERNAME: str     = os.getenv("MQTT_USERNAME", "")
    MQTT_PASSWORD: str     = os.getenv("MQTT_PASSWORD", "")

    # ── Simulation parameters ─────────────────────────────────────
    NUM_DEVICES: int       = env_int("NUM_DEVICES", 10)
    PUBLISH_INTERVAL: float= env_float("PUBLISH_INTERVAL", 2.0)   # seconds between publishes
    RANDOM_SEED: int       = env_int("RANDOM_SEED", 42)
    DEVICE_PREFIX: str     = os.getenv("DEVICE_PREFIX", "truck")

    # ── Cargo type (frozen | chilled | ambient) ───────────────────
    # Affects nominal temperature and thresholds
    CARGO_TYPE: str        = os.getenv("CARGO_TYPE", "frozen")

    # ── Scenario injection (comma-separated) ─────────────────────
    # Valid values: door_open, compressor_fail, gps_jump, sensor_stuck
    INCIDENTS_RAW: str     = os.getenv("INCIDENTS", "")

    @property
    def incidents(self) -> list[str]:
        if not self.INCIDENTS_RAW:
            return []
        return [s.strip().lower() for s in self.INCIDENTS_RAW.split(",") if s.strip()]

    # ── Cargo temperature setpoints ───────────────────────────────
    CARGO_SETPOINTS: dict[str, float] = {
        "frozen":   -18.0,
        "chilled":    4.0,
        "ambient":   20.0,
    }

    @property
    def nominal_temp(self) -> float:
        return self.CARGO_SETPOINTS.get(self.CARGO_TYPE, -18.0)

    # ── Downsampling ratio for telemetry forwarding ───────────────
    # Edge will forward 1-in-N raw telemetry messages.
    # Simulator itself always publishes at PUBLISH_INTERVAL.
    DOWNSAMPLE_RATIO: int  = env_int("DOWNSAMPLE_RATIO", 10)

    # ── GPS starting region (rough bounding box for a logistics hub) ─
    GPS_LAT_MIN: float     = env_float("GPS_LAT_MIN", 37.70)
    GPS_LAT_MAX: float     = env_float("GPS_LAT_MAX", 37.90)
    GPS_LON_MIN: float     = env_float("GPS_LON_MIN", -122.55)
    GPS_LON_MAX: float     = env_float("GPS_LON_MAX", -122.35)
