"""
Runtime control registry for the Cold-Chain Sentinel simulator.

The simulator subscribes to ``coldchain/control/{device_id}`` and forwards
every JSON command to this registry.  Each DeviceSimulator polls its
``DeviceOverrides`` object on every tick.

Control command format (JSON published to MQTT)
-----------------------------------------------
Set door state (force open or closed):
    {"cmd": "set_door", "value": true}

Override temperature reading:
    {"cmd": "set_temp",    "value": -5.0}     # force this temp
    {"cmd": "set_temp",    "value": null}      # clear override

Override battery voltage:
    {"cmd": "set_battery", "value": 11.0}     # force this voltage
    {"cmd": "set_battery", "value": null}      # clear override

Add / remove a named scenario:
    {"cmd": "add_scenario",   "scenario": "compressor_fail"}
    {"cmd": "clear_scenario", "scenario": "compressor_fail"}

Clear door override (let physics decide again):
    {"cmd": "clear_door"}

Reset ALL overrides for this device:
    {"cmd": "reset"}
"""
from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Per-device overrides dataclass
# ---------------------------------------------------------------------------

@dataclass
class DeviceOverrides:
    """
    Runtime overrides for a single device.

    Any field set to ``None`` means "let the physics model decide".
    The ``scenarios`` list contains extra scenario names to inject beyond
    whatever the device was originally configured with.
    """
    door_open:  Optional[bool]  = None   # None → physics decides
    temp_c:     Optional[float] = None   # None → physics decides
    battery_v:  Optional[float] = None   # None → physics decides
    scenarios:  list[str]       = field(default_factory=list)


# ---------------------------------------------------------------------------
# Thread-safe registry
# ---------------------------------------------------------------------------

class ControlRegistry:
    """
    Central, thread-safe store of per-device runtime overrides.

    The MQTT control listener calls :meth:`apply_command` from the asyncio
    event loop.  DeviceSimulator tasks read via :meth:`get` (also async).
    Both are safe because Python's GIL and the fact that we hold a lock
    around every mutation.
    """

    def __init__(self) -> None:
        self._lock: threading.Lock = threading.Lock()
        self._overrides: dict[str, DeviceOverrides] = {}

    # ── Reads ────────────────────────────────────────────────────────────────

    def get(self, device_id: str) -> DeviceOverrides:
        """Return a *copy* of the overrides for *device_id*."""
        with self._lock:
            ov = self._overrides.get(device_id)
            if ov is None:
                return DeviceOverrides()
            # Return a shallow copy so the caller can read without racing
            return DeviceOverrides(
                door_open = ov.door_open,
                temp_c    = ov.temp_c,
                battery_v = ov.battery_v,
                scenarios = list(ov.scenarios),
            )

    # ── Writes ───────────────────────────────────────────────────────────────

    def apply_command(self, device_id: str, msg: dict) -> str:
        """
        Parse and apply a control command dict for *device_id*.

        Returns a short description of what was done (for logging).
        Silently ignores unknown commands.
        """
        with self._lock:
            ov = self._overrides.setdefault(device_id, DeviceOverrides())
            cmd = msg.get("cmd", "")

            if cmd == "set_door":
                ov.door_open = bool(msg.get("value", False))
                return f"door_open → {ov.door_open}"

            elif cmd == "clear_door":
                ov.door_open = None
                return "door_open → physics"

            elif cmd == "set_temp":
                val = msg.get("value")
                ov.temp_c = float(val) if val is not None else None
                return f"temp_c → {ov.temp_c}"

            elif cmd == "set_battery":
                val = msg.get("value")
                ov.battery_v = float(val) if val is not None else None
                return f"battery_v → {ov.battery_v}"

            elif cmd == "add_scenario":
                scenario = str(msg.get("scenario", "")).strip()
                if scenario and scenario not in ov.scenarios:
                    ov.scenarios.append(scenario)
                return f"scenario + {scenario!r}"

            elif cmd == "clear_scenario":
                scenario = str(msg.get("scenario", "")).strip()
                ov.scenarios = [s for s in ov.scenarios if s != scenario]
                return f"scenario - {scenario!r}"

            elif cmd == "reset":
                self._overrides[device_id] = DeviceOverrides()
                return "reset all overrides"

            else:
                return f"unknown cmd {cmd!r} (ignored)"

    # ── Diagnostics ──────────────────────────────────────────────────────────

    def snapshot(self) -> dict[str, dict]:
        """Return a JSON-serialisable view of all active overrides."""
        with self._lock:
            result = {}
            for did, ov in self._overrides.items():
                if (ov.door_open is not None
                        or ov.temp_c    is not None
                        or ov.battery_v is not None
                        or ov.scenarios):
                    result[did] = {
                        "door_open":  ov.door_open,
                        "temp_c":     ov.temp_c,
                        "battery_v":  ov.battery_v,
                        "scenarios":  ov.scenarios,
                    }
            return result
