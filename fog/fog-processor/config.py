"""
Fog Processor configuration.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from shared.utils import env_int, env_float, env_bool


class FogConfig:
    # ── Local MQTT broker ─────────────────────────────────────────
    LOCAL_MQTT_HOST: str   = os.getenv("MQTT_HOST", "mosquitto")
    LOCAL_MQTT_PORT: int   = env_int("MQTT_PORT", 1883)
    MQTT_USERNAME: str     = os.getenv("MQTT_USERNAME", "")
    MQTT_PASSWORD: str     = os.getenv("MQTT_PASSWORD", "")
    FOG_CLIENT_ID: str     = os.getenv("FOG_CLIENT_ID", "fog-processor-001")

    # ── AWS IoT Core ──────────────────────────────────────────────
    # Set to empty string to run in local-only mode (no AWS forwarding)
    AWS_IOT_ENDPOINT: str  = os.getenv("AWS_IOT_ENDPOINT", "")
    AWS_IOT_PORT: int      = env_int("AWS_IOT_PORT", 8883)
    AWS_IOT_CLIENT_ID: str = os.getenv("AWS_IOT_CLIENT_ID", "fog-gateway-001")

    # Certificate paths (mounted from secrets / volume)
    AWS_IOT_CERT_PATH: str = os.getenv("AWS_IOT_CERT_PATH", "/certs/device-cert.pem")
    AWS_IOT_KEY_PATH:  str = os.getenv("AWS_IOT_KEY_PATH",  "/certs/private-key.pem")
    AWS_IOT_CA_PATH:   str = os.getenv("AWS_IOT_CA_PATH",   "/certs/AmazonRootCA1.pem")

    # ── Offline buffer ────────────────────────────────────────────
    BUFFER_DB_PATH: str    = os.getenv("BUFFER_DB_PATH", "/data/fog_buffer.db")
    BUFFER_FLUSH_INTERVAL: float = env_float("BUFFER_FLUSH_INTERVAL", 10.0)  # seconds
    BUFFER_MAX_SIZE: int   = env_int("BUFFER_MAX_SIZE", 10_000)   # max buffered messages

    # ── HTTP metrics server ───────────────────────────────────────
    HTTP_HOST: str         = os.getenv("FOG_HTTP_HOST", "0.0.0.0")
    HTTP_PORT: int         = env_int("FOG_HTTP_PORT", 8080)

    # ── AWS region (for SDK calls if needed) ─────────────────────
    AWS_REGION: str        = os.getenv("AWS_REGION", "us-east-1")
