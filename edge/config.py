"""
Edge processor configuration.
All values read from environment variables with sensible defaults.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shared.utils import env_int, env_float, env_bool


class EdgeConfig:
    # ── MQTT broker (same Mosquitto instance as simulator) ────────
    MQTT_HOST: str   = os.getenv("MQTT_HOST", "localhost")
    MQTT_PORT: int   = env_int("MQTT_PORT", 1883)
    MQTT_USERNAME: str = os.getenv("MQTT_USERNAME", "")
    MQTT_PASSWORD: str = os.getenv("MQTT_PASSWORD", "")
    CLIENT_ID: str   = os.getenv("EDGE_CLIENT_ID", "edge-processor-001")

    # ── Downsampling ──────────────────────────────────────────────
    # Forward 1-in-N raw telemetry messages to the telemetry topic
    DOWNSAMPLE_N: int = env_int("EDGE_DOWNSAMPLE_N", 10)

    # ── Rules thresholds ─────────────────────────────────────────
    # Temperature excursion: alert if temp_c > TEMP_MAX_C for N consecutive readings
    TEMP_MAX_C: float          = env_float("EDGE_TEMP_MAX_C", -15.0)   # frozen cargo
    TEMP_EXCURSION_WINDOW: int = env_int("EDGE_TEMP_EXCURSION_WINDOW", 3)

    # Door open too long: alert after DOOR_OPEN_SECONDS
    DOOR_OPEN_SECONDS: float   = env_float("EDGE_DOOR_OPEN_SECONDS", 300.0)  # 5 min

    # Battery low threshold
    BATTERY_LOW_V: float       = env_float("EDGE_BATTERY_LOW_V", 11.2)

    # Sensor stuck: same value for N consecutive readings
    SENSOR_STUCK_WINDOW: int   = env_int("EDGE_SENSOR_STUCK_WINDOW", 10)
    SENSOR_STUCK_EPSILON: float= env_float("EDGE_SENSOR_STUCK_EPSILON", 0.001)

    # GPS jump: alert if distance > GPS_JUMP_KM km in one tick
    GPS_JUMP_KM: float         = env_float("EDGE_GPS_JUMP_KM", 50.0)

    # ── Anomaly detection (EWMA / z-score) ───────────────────────
    EWMA_ALPHA: float          = env_float("EDGE_EWMA_ALPHA", 0.1)
    ANOMALY_ZSCORE_THRESHOLD: float = env_float("EDGE_ANOMALY_ZSCORE", 3.0)
    # Minimum samples before anomaly scoring is active
    ANOMALY_MIN_SAMPLES: int   = env_int("EDGE_ANOMALY_MIN_SAMPLES", 30)
