"""
Cold-Chain Sentinel — Edge Processor
======================================
Subscribes to coldchain/+/raw, runs rules + anomaly detection,
then publishes:
  - coldchain/{device_id}/telemetry  (downsampled, EWMA-annotated)
  - coldchain/{device_id}/events     (rule violations + anomalies)

All events are also written to structured logs for local observability.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import aiomqtt

from edge.anomaly import AnomalyDetector
from edge.config import EdgeConfig
from edge.rules import DeviceRuleState, evaluate_rules
from shared.schemas import EventPayload, TelemetryPayload
from shared.topics import (
    SUB_ALL_RAW,
    device_id_from_topic,
    events as events_topic,
    telemetry as telemetry_topic,
)
from shared.utils import get_logger, get_metrics, inc, set_gauge

log = get_logger("edge")


# ---------------------------------------------------------------------------
# Per-device counters for downsampling
# ---------------------------------------------------------------------------

class DownsampleCounter:
    def __init__(self, n: int) -> None:
        self._n = n
        self._counts: dict[str, int] = {}

    def should_forward(self, device_id: str) -> bool:
        c = self._counts.get(device_id, 0)
        self._counts[device_id] = (c + 1) % self._n
        return c == 0


# ---------------------------------------------------------------------------
# Main processor coroutine
# ---------------------------------------------------------------------------

async def run_edge(cfg: EdgeConfig) -> None:
    log.info(
        "edge processor starting",
        extra={
            "broker":           f"{cfg.MQTT_HOST}:{cfg.MQTT_PORT}",
            "downsample_n":     cfg.DOWNSAMPLE_N,
            "temp_max_c":       cfg.TEMP_MAX_C,
            "door_open_secs":   cfg.DOOR_OPEN_SECONDS,
            "battery_low_v":    cfg.BATTERY_LOW_V,
            "ewma_alpha":       cfg.EWMA_ALPHA,
            "zscore_threshold": cfg.ANOMALY_ZSCORE_THRESHOLD,
        },
    )

    detector      = AnomalyDetector(cfg)
    downsample    = DownsampleCounter(cfg.DOWNSAMPLE_N)
    rule_states: dict[str, DeviceRuleState] = {}

    while True:
        try:
            client_kwargs: dict = {
                "hostname":  cfg.MQTT_HOST,
                "port":      cfg.MQTT_PORT,
                "keepalive": 30,
                "identifier": cfg.CLIENT_ID,
            }
            if cfg.MQTT_USERNAME:
                client_kwargs["username"] = cfg.MQTT_USERNAME
                client_kwargs["password"] = cfg.MQTT_PASSWORD

            async with aiomqtt.Client(**client_kwargs) as client:
                log.info("mqtt connected")
                await client.subscribe(SUB_ALL_RAW, qos=0)

                async for message in client.messages:
                    topic   = str(message.topic)
                    payload = message.payload

                    try:
                        await _process_message(
                            topic, payload, client,
                            cfg, detector, downsample, rule_states,
                        )
                    except Exception as exc:  # noqa: BLE001
                        log.error(
                            "message processing error",
                            extra={"topic": topic, "error": str(exc)},
                        )
                        inc("edge.processing_errors")

        except aiomqtt.MqttError as exc:
            log.warning("mqtt disconnected, retrying in 5 s", extra={"error": str(exc)})
            inc("edge.connect_errors")
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            log.info("edge processor shutting down")
            return


async def _process_message(
    topic: str,
    raw_payload: bytes,
    client: aiomqtt.Client,
    cfg: EdgeConfig,
    detector: AnomalyDetector,
    downsample: DownsampleCounter,
    rule_states: dict[str, DeviceRuleState],
) -> None:
    inc("edge.messages_received")

    # Parse raw telemetry
    try:
        data = json.loads(raw_payload)
        tel = TelemetryPayload.model_validate(data)
    except Exception as exc:
        log.warning("invalid payload", extra={"topic": topic, "error": str(exc)})
        inc("edge.parse_errors")
        return

    device_id = tel.device_id

    # Ensure per-device rule state exists
    if device_id not in rule_states:
        rule_states[device_id] = DeviceRuleState()

    # 1. Rules-based detection
    rule_events = evaluate_rules(tel, rule_states[device_id], cfg)

    # 2. EWMA anomaly detection (also annotates payload)
    annotated_tel, anomaly_events = detector.update(tel, cfg)

    all_events = rule_events + anomaly_events

    # 3. Publish events
    for evt in all_events:
        await _publish_event(client, evt)
        inc("edge.events_published")

    # 4. Downsample: forward 1-in-N telemetry messages
    if downsample.should_forward(device_id):
        await client.publish(
            telemetry_topic(device_id),
            payload=annotated_tel.model_dump_json(),
            qos=0,
        )
        inc("edge.telemetry_forwarded")
    else:
        inc("edge.telemetry_dropped")

    # 5. Update gauges for metrics endpoint
    set_gauge("edge.active_devices", len(rule_states))
    set_gauge("edge.anomaly_detector_devices", detector.device_count)


async def _publish_event(client: aiomqtt.Client, evt: EventPayload) -> None:
    topic = events_topic(evt.device_id)
    await client.publish(topic, payload=evt.model_dump_json(), qos=1)
    log.info(
        "event published",
        extra={
            "device_id":  evt.device_id,
            "event_type": evt.event_type.value,
            "severity":   evt.severity.value,
            "reason":     evt.reason,
        },
    )


# ---------------------------------------------------------------------------
# Metrics printer (background task)
# ---------------------------------------------------------------------------

async def _print_metrics(interval: float = 30.0) -> None:
    while True:
        await asyncio.sleep(interval)
        m = get_metrics()
        log.info("metrics snapshot", extra=m)


# ---------------------------------------------------------------------------
# Entry-point
# ---------------------------------------------------------------------------

async def main() -> None:
    cfg = EdgeConfig()
    await asyncio.gather(
        run_edge(cfg),
        _print_metrics(),
    )


if __name__ == "__main__":
    asyncio.run(main())
