"""
In-memory state for the dashboard API.

Stores the latest telemetry snapshot, temperature history (ring buffer),
and last-known event for every device seen on the MQTT bus, plus a
global event deque.  Thread-safe via asyncio (single-threaded).
"""
from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from typing import Optional

from dashboard.api.config import DashboardConfig

cfg = DashboardConfig()


# ─── per-device snapshot ─────────────────────────────────────────────────────

@dataclass
class DeviceSnapshot:
    device_id:   str
    last_seen:   float              = 0.0
    telemetry:   dict               = field(default_factory=dict)
    # [(ts, temp_c), ...] — oldest first
    temp_history: list              = field(default_factory=list)
    last_event:  Optional[dict]     = None
    status:      str                = "unknown"   # normal | warning | critical | offline


# ─── state manager ───────────────────────────────────────────────────────────

class StateManager:
    def __init__(self) -> None:
        self._devices: dict[str, DeviceSnapshot]  = {}
        self._histories: dict[str, deque]          = {}
        self._events:  deque = deque(maxlen=cfg.MAX_EVENTS)

    # ── telemetry ─────────────────────────────────────────────────────────────

    def update_telemetry(self, payload: dict) -> DeviceSnapshot:
        device_id = payload["device_id"]
        if device_id not in self._devices:
            self._devices[device_id]  = DeviceSnapshot(device_id=device_id)
            self._histories[device_id] = deque(maxlen=cfg.HISTORY_LEN)

        snap = self._devices[device_id]
        snap.telemetry = payload
        snap.last_seen = payload.get("ts", time.time())

        # Append to ring buffer
        self._histories[device_id].append((
            snap.last_seen,
            payload.get("temp_c", 0.0),
            payload.get("ewma_temp"),
            payload.get("anomaly_score"),
        ))
        snap.temp_history = list(self._histories[device_id])
        snap.status       = self._compute_status(snap)
        return snap

    def add_event(self, payload: dict) -> None:
        device_id = payload.get("device_id", "unknown")
        self._events.appendleft(payload)        # newest first

        if device_id in self._devices:
            snap = self._devices[device_id]
            snap.last_event = payload
            snap.status     = self._compute_status(snap)

    # ── helpers ───────────────────────────────────────────────────────────────

    def _compute_status(self, snap: DeviceSnapshot) -> str:
        now = time.time()
        if now - snap.last_seen > cfg.OFFLINE_SECS:
            return "offline"
        temp = snap.telemetry.get("temp_c")
        if temp is None:
            return "unknown"
        if temp > cfg.TEMP_CRIT_C:
            return "critical"
        # Escalate if there is a recent CRITICAL event (within 5 min)
        if snap.last_event:
            sev = snap.last_event.get("severity", "")
            evt_age = now - snap.last_event.get("ts", 0)
            if sev == "CRITICAL" and evt_age < 300:
                return "critical"
            if sev == "WARNING" and evt_age < 300:
                return "warning" if temp >= cfg.TEMP_WARN_C else "warning"
        if temp > cfg.TEMP_WARN_C:
            return "warning"
        return "normal"

    # ── getters ───────────────────────────────────────────────────────────────

    @property
    def devices(self) -> dict[str, DeviceSnapshot]:
        return self._devices

    @property
    def events(self) -> list[dict]:
        return list(self._events)

    def get_stats(self) -> dict:
        now = time.time()
        snaps = list(self._devices.values())
        temps = [s.telemetry.get("temp_c") for s in snaps
                 if s.telemetry.get("temp_c") is not None
                 and now - s.last_seen < cfg.OFFLINE_SECS]

        status_counts: dict[str, int] = {"normal": 0, "warning": 0, "critical": 0, "offline": 0}
        open_doors = 0
        low_battery = 0
        for s in snaps:
            status_counts[s.status] = status_counts.get(s.status, 0) + 1
            if s.telemetry.get("door_open"):
                open_doors += 1
            bv = s.telemetry.get("battery_v", 99)
            if bv < 11.5:
                low_battery += 1

        return {
            "total_devices": len(snaps),
            "online_devices": len([s for s in snaps if s.status != "offline"]),
            "avg_temp_c":   round(sum(temps) / len(temps), 2) if temps else None,
            "min_temp_c":   round(min(temps), 2) if temps else None,
            "max_temp_c":   round(max(temps), 2) if temps else None,
            "open_doors":   open_doors,
            "low_battery":  low_battery,
            "active_alerts": status_counts.get("critical", 0) + status_counts.get("warning", 0),
            "critical_count": status_counts.get("critical", 0),
            "warning_count":  status_counts.get("warning", 0),
            "total_events":   len(self._events),
        }

    def devices_as_dicts(self) -> dict:
        return {
            did: {
                "device_id":    s.device_id,
                "last_seen":    s.last_seen,
                "telemetry":    s.telemetry,
                "temp_history": s.temp_history,
                "last_event":   s.last_event,
                "status":       s.status,
            }
            for did, s in self._devices.items()
        }
