"""
Cold-Chain Sentinel — Dashboard API
=====================================
FastAPI service that:
  1. Subscribes to local Mosquitto (coldchain/+/telemetry and /events)
  2. Maintains in-memory device state + event log
  3. Broadcasts real-time updates over WebSocket to browser clients
  4. Exposes REST endpoints for initial page load
  5. Serves the built React app as static files

Port: 5001 (configurable via DASH_PORT env var)
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from contextlib import asynccontextmanager

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

import aiomqtt
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from dashboard.api.config import DashboardConfig
from dashboard.api.state import StateManager
from dashboard.api.ws_manager import ConnectionManager
from shared.topics import SUB_ALL_EVENTS, SUB_ALL_TELEMETRY
from shared.utils import get_logger, inc

log   = get_logger("dashboard")
cfg   = DashboardConfig()
state = StateManager()
wsmgr = ConnectionManager()


# ─── background tasks ────────────────────────────────────────────────────────

async def mqtt_subscriber() -> None:
    """Subscribe to edge-processed telemetry and events; update state + broadcast."""
    log.info("dashboard mqtt subscriber starting",
             extra={"broker": f"{cfg.MQTT_HOST}:{cfg.MQTT_PORT}"})
    while True:
        try:
            kw: dict = {"hostname": cfg.MQTT_HOST, "port": cfg.MQTT_PORT,
                        "keepalive": 30, "identifier": "dashboard-api"}
            if cfg.MQTT_USERNAME:
                kw["username"] = cfg.MQTT_USERNAME
                kw["password"] = cfg.MQTT_PASSWORD

            async with aiomqtt.Client(**kw) as client:
                log.info("mqtt connected")
                await client.subscribe(SUB_ALL_TELEMETRY, qos=0)
                await client.subscribe(SUB_ALL_EVENTS,    qos=1)

                async for msg in client.messages:
                    topic   = str(msg.topic)
                    kind    = topic.rsplit("/", 1)[-1]   # "telemetry" or "events"
                    try:
                        payload = json.loads(msg.payload)
                    except Exception:
                        continue

                    if kind == "telemetry":
                        snap = state.update_telemetry(payload)
                        inc("dash.telemetry_received")
                        await wsmgr.broadcast({
                            "type":      "telemetry",
                            "device_id": snap.device_id,
                            "data":      snap.telemetry,
                            "history":   snap.temp_history,
                            "status":    snap.status,
                        })

                    elif kind == "events":
                        state.add_event(payload)
                        inc("dash.events_received")
                        await wsmgr.broadcast({
                            "type": "event",
                            "data": payload,
                        })

        except aiomqtt.MqttError as exc:
            log.warning("mqtt disconnected, retrying in 5 s",
                        extra={"error": str(exc)})
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            return


async def stats_broadcaster() -> None:
    """Push aggregate stats to all WebSocket clients every 5 seconds."""
    while True:
        await asyncio.sleep(5)
        if wsmgr.count:
            await wsmgr.broadcast({"type": "stats", "data": state.get_stats()})


# ─── lifespan ────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    t1 = asyncio.create_task(mqtt_subscriber())
    t2 = asyncio.create_task(stats_broadcaster())
    yield
    t1.cancel(); t2.cancel()
    await asyncio.gather(t1, t2, return_exceptions=True)


# ─── FastAPI app ──────────────────────────────────────────────────────────────

app = FastAPI(title="Cold-Chain Dashboard API", version="1.0.0",
              lifespan=lifespan)


# ─── REST endpoints ───────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return {"status": "ok", "ws_clients": wsmgr.count,
            "devices": len(state.devices)}

@app.get("/api/devices")
async def list_devices():
    return JSONResponse(state.devices_as_dicts())

@app.get("/api/devices/{device_id}")
async def get_device(device_id: str):
    snap = state.devices.get(device_id)
    if snap is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse({
        "device_id":    snap.device_id,
        "last_seen":    snap.last_seen,
        "telemetry":    snap.telemetry,
        "temp_history": snap.temp_history,
        "last_event":   snap.last_event,
        "status":       snap.status,
    })

@app.get("/api/events")
async def list_events(limit: int = 100):
    return JSONResponse(state.events[:min(limit, cfg.MAX_EVENTS)])

@app.get("/api/stats")
async def get_stats():
    return JSONResponse(state.get_stats())


# ─── WebSocket ────────────────────────────────────────────────────────────────

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await wsmgr.connect(ws)
    # Send full state snapshot immediately on connect
    await ws.send_text(json.dumps({
        "type":    "init",
        "devices": state.devices_as_dicts(),
        "events":  state.events,
        "stats":   state.get_stats(),
        "ts":      time.time(),
    }, default=str))
    try:
        while True:
            data = await ws.receive_text()
            msg  = json.loads(data)
            if msg.get("type") == "ping":
                await ws.send_text(json.dumps({"type": "pong", "ts": time.time()}))
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        wsmgr.disconnect(ws)


# ─── Serve built React app ────────────────────────────────────────────────────
# Must come LAST — it catches everything not matched above.

_STATIC = cfg.STATIC_DIR
if os.path.isdir(_STATIC):
    app.mount("/", StaticFiles(directory=_STATIC, html=True), name="ui")
else:
    @app.get("/")
    async def dev_note():
        return JSONResponse({
            "message": "React UI not built yet. Run: cd dashboard/ui && npm run build",
            "api_docs": "/docs",
        })


# ─── Entry-point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run("dashboard.api.main:app",
                host=cfg.HTTP_HOST, port=cfg.HTTP_PORT,
                log_config=None, access_log=False)
