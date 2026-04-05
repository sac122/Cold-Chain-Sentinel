"""
Rules-based anomaly detection for the edge processor.

Each DeviceRuleState tracks per-device counters and timestamps needed by
the rule engine.  Rules are stateless functions that accept
(payload, state, config) and return a list of EventPayload objects
(empty if no rule fires).

Rules implemented
-----------------
1. TEMP_EXCURSION  – temp_c > TEMP_MAX_C for N consecutive samples
2. DOOR_OPEN_TOO_LONG – door_open=True for > DOOR_OPEN_SECONDS
3. BATTERY_LOW     – battery_v < BATTERY_LOW_V
4. SENSOR_STUCK    – |temp_c[i] - temp_c[i-1]| < ε for N consecutive samples
5. GPS_JUMP        – Haversine distance between consecutive positions > GPS_JUMP_KM
"""
from __future__ import annotations

import math
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from shared.schemas import EventPayload, EventSeverity, EventType, GPSCoord, TelemetryPayload
from edge.config import EdgeConfig


# ---------------------------------------------------------------------------
# Per-device rule state
# ---------------------------------------------------------------------------

@dataclass
class DeviceRuleState:
    # TEMP_EXCURSION
    temp_excursion_count: int = 0

    # DOOR_OPEN_TOO_LONG
    door_open_since: Optional[float] = None
    door_event_fired: bool = False

    # BATTERY_LOW (fire once per dip below threshold, reset when back above)
    battery_low_active: bool = False

    # SENSOR_STUCK
    last_temp_readings: list[float] = field(default_factory=list)

    # GPS_JUMP
    last_lat: Optional[float] = None
    last_lon: Optional[float] = None


# ---------------------------------------------------------------------------
# Haversine distance
# ---------------------------------------------------------------------------

def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


# ---------------------------------------------------------------------------
# Rule engine
# ---------------------------------------------------------------------------

def evaluate_rules(
    payload: TelemetryPayload,
    state: DeviceRuleState,
    cfg: EdgeConfig,
) -> list[EventPayload]:
    """Run all rules against the current payload.  Returns fired events."""
    events: list[EventPayload] = []
    now = time.time()

    # 1. TEMP_EXCURSION ────────────────────────────────────────────────────────
    if payload.temp_c > cfg.TEMP_MAX_C:
        state.temp_excursion_count += 1
    else:
        state.temp_excursion_count = 0

    if state.temp_excursion_count == cfg.TEMP_EXCURSION_WINDOW:
        events.append(EventPayload(
            device_id  = payload.device_id,
            event_type = EventType.TEMP_EXCURSION,
            severity   = EventSeverity.CRITICAL,
            reason     = (
                f"Temperature {payload.temp_c:.2f} °C exceeded "
                f"{cfg.TEMP_MAX_C} °C for {cfg.TEMP_EXCURSION_WINDOW} "
                f"consecutive readings"
            ),
            telemetry  = payload,
        ))

    # 2. DOOR_OPEN_TOO_LONG ───────────────────────────────────────────────────
    if payload.door_open:
        if state.door_open_since is None:
            state.door_open_since = now
            state.door_event_fired = False
        elapsed = now - state.door_open_since
        if elapsed >= cfg.DOOR_OPEN_SECONDS and not state.door_event_fired:
            events.append(EventPayload(
                device_id        = payload.device_id,
                event_type       = EventType.DOOR_OPEN_TOO_LONG,
                severity         = EventSeverity.WARNING,
                reason           = f"Cargo door open for {elapsed:.0f} s (threshold {cfg.DOOR_OPEN_SECONDS:.0f} s)",
                telemetry        = payload,
                duration_seconds = elapsed,
            ))
            state.door_event_fired = True
    else:
        state.door_open_since   = None
        state.door_event_fired  = False

    # 3. BATTERY_LOW ──────────────────────────────────────────────────────────
    if payload.battery_v < cfg.BATTERY_LOW_V:
        if not state.battery_low_active:
            events.append(EventPayload(
                device_id  = payload.device_id,
                event_type = EventType.BATTERY_LOW,
                severity   = EventSeverity.WARNING,
                reason     = f"Battery {payload.battery_v:.2f} V below threshold {cfg.BATTERY_LOW_V} V",
                telemetry  = payload,
            ))
            state.battery_low_active = True
    else:
        state.battery_low_active = False

    # 4. SENSOR_STUCK ─────────────────────────────────────────────────────────
    readings = state.last_temp_readings
    readings.append(payload.temp_c)
    # Keep only a sliding window
    window = cfg.SENSOR_STUCK_WINDOW
    if len(readings) > window:
        readings.pop(0)

    if len(readings) == window:
        spread = max(readings) - min(readings)
        if spread < cfg.SENSOR_STUCK_EPSILON:
            events.append(EventPayload(
                device_id  = payload.device_id,
                event_type = EventType.SENSOR_STUCK,
                severity   = EventSeverity.WARNING,
                reason     = (
                    f"Temperature sensor appears stuck at "
                    f"{payload.temp_c:.3f} °C for {window} samples "
                    f"(spread {spread:.6f} < {cfg.SENSOR_STUCK_EPSILON})"
                ),
                telemetry  = payload,
            ))

    # 5. GPS_JUMP ─────────────────────────────────────────────────────────────
    lat, lon = payload.gps.lat, payload.gps.lon
    if state.last_lat is not None and state.last_lon is not None:
        dist = _haversine_km(state.last_lat, state.last_lon, lat, lon)
        if dist > cfg.GPS_JUMP_KM:
            events.append(EventPayload(
                device_id  = payload.device_id,
                event_type = EventType.GPS_JUMP,
                severity   = EventSeverity.WARNING,
                reason     = (
                    f"GPS position jumped {dist:.1f} km in one tick "
                    f"(threshold {cfg.GPS_JUMP_KM} km)"
                ),
                telemetry  = payload,
                prev_gps   = GPSCoord(lat=state.last_lat, lon=state.last_lon),
            ))
    state.last_lat = lat
    state.last_lon = lon

    return events
