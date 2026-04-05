"""
Cold-Chain Sentinel — Fog Processor
=====================================
Subscribes to local Mosquitto topics (coldchain/+/telemetry,
coldchain/+/events) and bridges messages to AWS IoT Core.

When AWS IoT Core is unreachable, messages are queued to a local
SQLite database and replayed when connectivity is restored.

Additionally exposes a FastAPI HTTP server on port 8080 for:
  GET /health     — liveness / readiness probe
  GET /metrics    — in-process counters and gauges
  GET /buffer     — current buffer depth
"""
from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

import aiomqtt
import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from fog.fog_processor.aws_bridge import AWSBridge
from fog.fog_processor.buffer import MessageBuffer
from fog.fog_processor.config import FogConfig
from shared.topics import (
    SUB_ALL_EVENTS,
    SUB_ALL_TELEMETRY,
    aws_events,
    aws_telemetry,
    device_id_from_topic,
    message_kind,
)
from shared.utils import get_logger, get_metrics, inc, set_gauge

log = get_logger("fog")

# ---------------------------------------------------------------------------
# Application globals (initialized in startup)
# ---------------------------------------------------------------------------

cfg     = FogConfig()
buffer  = MessageBuffer(cfg.BUFFER_DB_PATH, max_size=cfg.BUFFER_MAX_SIZE)
bridge  = AWSBridge(cfg)

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="Cold-Chain Fog Processor", version="1.0.0")


@app.on_event("startup")
async def _startup() -> None:
    await buffer.open()
    bridge.start()
    log.info("fog processor HTTP server ready")


@app.on_event("shutdown")
async def _shutdown() -> None:
    bridge.stop()
    await buffer.close()


@app.get("/health")
async def health() -> JSONResponse:
    buf_size = await buffer.size()
    return JSONResponse({
        "status":        "ok",
        "aws_connected": bridge.connected,
        "aws_enabled":   bridge.enabled,
        "buffer_size":   buf_size,
    })


@app.get("/metrics")
async def metrics() -> JSONResponse:
    m = get_metrics()
    m["buffer_size"] = await buffer.size()
    return JSONResponse(m)


@app.get("/buffer")
async def buffer_status() -> JSONResponse:
    size = await buffer.size()
    return JSONResponse({
        "size":     size,
        "max_size": cfg.BUFFER_MAX_SIZE,
        "pct_full": round(size / cfg.BUFFER_MAX_SIZE * 100, 1),
    })


# ---------------------------------------------------------------------------
# MQTT subscriber coroutine
# ---------------------------------------------------------------------------

async def mqtt_subscriber() -> None:
    log.info(
        "mqtt subscriber starting",
        extra={"broker": f"{cfg.LOCAL_MQTT_HOST}:{cfg.LOCAL_MQTT_PORT}"},
    )
    while True:
        try:
            client_kwargs: dict = {
                "hostname":  cfg.LOCAL_MQTT_HOST,
                "port":      cfg.LOCAL_MQTT_PORT,
                "keepalive": 30,
                "identifier": cfg.FOG_CLIENT_ID,
            }
            if cfg.MQTT_USERNAME:
                client_kwargs["username"] = cfg.MQTT_USERNAME
                client_kwargs["password"] = cfg.MQTT_PASSWORD

            async with aiomqtt.Client(**client_kwargs) as client:
                log.info("local mqtt connected")
                await client.subscribe(SUB_ALL_TELEMETRY, qos=0)
                await client.subscribe(SUB_ALL_EVENTS, qos=1)
                inc("fog.mqtt_connect_ok")

                async for message in client.messages:
                    await _handle_message(str(message.topic), message.payload)

        except aiomqtt.MqttError as exc:
            log.warning("local mqtt disconnected, retrying", extra={"error": str(exc)})
            inc("fog.mqtt_connect_errors")
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            log.info("mqtt subscriber cancelled")
            return


async def _handle_message(topic: str, payload: bytes) -> None:
    inc("fog.messages_received")
    payload_str = payload.decode("utf-8", errors="replace")

    try:
        device_id = device_id_from_topic(topic)
        kind      = message_kind(topic)   # "telemetry" or "events"
    except ValueError as exc:
        log.warning("cannot parse topic", extra={"topic": topic, "error": str(exc)})
        inc("fog.parse_errors")
        return

    # Map local topic → AWS IoT Core topic
    if kind == "telemetry":
        aws_topic = aws_telemetry(device_id)
    elif kind == "events":
        aws_topic = aws_events(device_id)
    else:
        log.debug("ignoring unknown kind", extra={"kind": kind, "topic": topic})
        return

    # Try to forward directly
    if bridge.enabled and bridge.connected:
        success = await bridge.publish(aws_topic, payload_str, qos=1)
        if success:
            inc("fog.messages_forwarded")
            return
        else:
            log.warning("forward failed, buffering", extra={"aws_topic": aws_topic})

    # Buffer for later replay
    queued = await buffer.enqueue(aws_topic, payload_str)
    if queued:
        inc("fog.messages_buffered")
    else:
        inc("fog.messages_dropped")


# ---------------------------------------------------------------------------
# Buffer flush coroutine
# ---------------------------------------------------------------------------

async def buffer_flush_loop() -> None:
    """Periodically drain buffered messages to AWS IoT Core."""
    while True:
        try:
            await asyncio.sleep(cfg.BUFFER_FLUSH_INTERVAL)
            if not bridge.enabled or not bridge.connected:
                continue

            batch = await buffer.peek_batch(limit=50)
            if not batch:
                continue

            log.info("flushing buffer", extra={"batch_size": len(batch)})
            flushed = 0
            for msg in batch:
                success = await bridge.publish(msg.topic, msg.payload, qos=1)
                if success:
                    await buffer.ack(msg.id)
                    flushed += 1
                    inc("fog.buffer_flushed")
                else:
                    await buffer.increment_attempts(msg.id)
                    break   # stop flushing if AWS becomes unavailable mid-batch

            if flushed:
                log.info("buffer flush complete", extra={"flushed": flushed})

            # Weekly cleanup of very old messages
            await buffer.purge_old(older_than_seconds=86400 * 7)

        except asyncio.CancelledError:
            return
        except Exception as exc:  # noqa: BLE001
            log.error("buffer flush error", extra={"error": str(exc)})


# ---------------------------------------------------------------------------
# Entry-point: run uvicorn + MQTT subscriber + buffer flush concurrently
# ---------------------------------------------------------------------------

async def _run_all() -> None:
    # Open buffer before anything else (also opened in FastAPI startup but
    # we call it here too so it's ready before MQTT subscriber starts)
    await buffer.open()
    bridge.start()

    uvi_config = uvicorn.Config(
        app,
        host            = cfg.HTTP_HOST,
        port            = cfg.HTTP_PORT,
        log_config      = None,
        access_log      = False,
    )
    server = uvicorn.Server(uvi_config)

    await asyncio.gather(
        server.serve(),
        mqtt_subscriber(),
        buffer_flush_loop(),
    )


if __name__ == "__main__":
    asyncio.run(_run_all())
