"""
AWS IoT Core bridge for the Fog Processor.

Uses paho-mqtt with mutual TLS to connect to the AWS IoT Core endpoint.
Runs the paho network loop in a background thread so it doesn't block
the asyncio event loop.

Certificate provisioning
------------------------
The fog gateway acts as an IoT Thing registered in AWS IoT Core.
The X.509 certificate + private key are mounted into the container at
the paths specified in FogConfig (AWS_IOT_CERT_PATH, AWS_IOT_KEY_PATH).

In ECS, these are delivered via AWS Secrets Manager secrets mounted as
environment variables and written to a tmpfs volume at task start
(see ecs.tf for the sidecar approach, or the entrypoint script).

Alternatively, for development, copy the files directly into /certs/.
"""
from __future__ import annotations

import asyncio
import os
import ssl
import threading
import time
from typing import Callable, Optional

import paho.mqtt.client as mqtt

from fog.fog_processor.config import FogConfig
from shared.utils import get_logger, inc, set_gauge

log = get_logger("fog.aws_bridge")


class AWSBridge:
    """
    Thread-safe wrapper around a paho MQTT client connecting to AWS IoT Core.
    Exposes an async-friendly publish() coroutine.
    """

    RECONNECT_DELAY_MAX = 60   # seconds

    def __init__(self, cfg: FogConfig) -> None:
        self._cfg       = cfg
        self._client: Optional[mqtt.Client] = None
        self._connected = False
        self._lock      = threading.Lock()
        self._connect_event = threading.Event()

    # ── Properties ───────────────────────────────────────────────────────────

    @property
    def connected(self) -> bool:
        return self._connected

    @property
    def enabled(self) -> bool:
        """False when no AWS endpoint is configured (local-only mode)."""
        return bool(self._cfg.AWS_IOT_ENDPOINT)

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def start(self) -> None:
        """Initialize and start the paho client background thread."""
        if not self.enabled:
            log.info("aws bridge disabled (no AWS_IOT_ENDPOINT set) — local-only mode")
            return

        # Validate certificate files exist
        for path, label in [
            (self._cfg.AWS_IOT_CERT_PATH, "cert"),
            (self._cfg.AWS_IOT_KEY_PATH,  "key"),
            (self._cfg.AWS_IOT_CA_PATH,   "CA"),
        ]:
            if not os.path.exists(path):
                log.warning(
                    "certificate file missing",
                    extra={"label": label, "path": path},
                )

        # paho-mqtt 2.x requires an explicit callback_api_version.
        # VERSION1 keeps the classic (1.x-compatible) callback signatures so
        # nothing else in this class needs to change.
        client = mqtt.Client(
            callback_api_version = mqtt.CallbackAPIVersion.VERSION1,
            client_id            = self._cfg.AWS_IOT_CLIENT_ID,
            protocol             = mqtt.MQTTv311,
            clean_session        = True,
        )
        client.tls_set(
            ca_certs   = self._cfg.AWS_IOT_CA_PATH,
            certfile   = self._cfg.AWS_IOT_CERT_PATH,
            keyfile    = self._cfg.AWS_IOT_KEY_PATH,
            tls_version= ssl.PROTOCOL_TLS_CLIENT,
        )
        client.on_connect    = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_publish    = self._on_publish

        # Exponential back-off reconnect
        client.reconnect_delay_set(min_delay=1, max_delay=self.RECONNECT_DELAY_MAX)

        self._client = client
        client.connect_async(self._cfg.AWS_IOT_ENDPOINT, self._cfg.AWS_IOT_PORT)
        client.loop_start()
        log.info(
            "aws bridge starting",
            extra={
                "endpoint": self._cfg.AWS_IOT_ENDPOINT,
                "port":     self._cfg.AWS_IOT_PORT,
                "client_id": self._cfg.AWS_IOT_CLIENT_ID,
            },
        )

    def stop(self) -> None:
        if self._client:
            self._client.loop_stop()
            self._client.disconnect()
            self._client = None
        self._connected = False

    # ── Paho callbacks ────────────────────────────────────────────────────────

    def _on_connect(self, client, userdata, flags, rc) -> None:  # noqa: ANN001
        if rc == 0:
            self._connected = True
            self._connect_event.set()
            inc("fog.aws_connect_ok")
            log.info("connected to AWS IoT Core", extra={"rc": rc})
            set_gauge("fog.aws_connected", 1.0)
        else:
            self._connected = False
            log.warning("aws connect failed", extra={"rc": rc})
            set_gauge("fog.aws_connected", 0.0)

    def _on_disconnect(self, client, userdata, rc) -> None:  # noqa: ANN001
        self._connected = False
        set_gauge("fog.aws_connected", 0.0)
        if rc != 0:
            log.warning("aws disconnected unexpectedly", extra={"rc": rc})
            inc("fog.aws_disconnects")
        else:
            log.info("aws disconnected cleanly")

    def _on_publish(self, client, userdata, mid) -> None:  # noqa: ANN001
        inc("fog.aws_messages_published")

    # ── Async publish ─────────────────────────────────────────────────────────

    async def publish(self, topic: str, payload: str, qos: int = 1) -> bool:
        """
        Publish a message to AWS IoT Core.
        Returns True on success, False if not connected or bridge disabled.
        Must be called from the asyncio event loop.
        """
        if not self.enabled or not self._connected or not self._client:
            return False
        loop = asyncio.get_event_loop()
        try:
            result = await loop.run_in_executor(
                None,
                lambda: self._client.publish(topic, payload, qos=qos),
            )
            return result.rc == mqtt.MQTT_ERR_SUCCESS
        except Exception as exc:  # noqa: BLE001
            log.error("aws publish error", extra={"topic": topic, "error": str(exc)})
            inc("fog.aws_publish_errors")
            return False

    # ── Wait for connection ───────────────────────────────────────────────────

    async def wait_connected(self, timeout: float = 30.0) -> bool:
        """Await initial connection. Returns True if connected within timeout."""
        if not self.enabled:
            return False
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            None,
            lambda: self._connect_event.wait(timeout=timeout),
        )
