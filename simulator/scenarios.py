"""
Scenario injection for Cold-Chain Sentinel simulator.

Each scenario is a callable that mutates a MutableTelemetryState object
for one device.  Scenarios are stateful (they track how many ticks have
elapsed since activation).

Available scenarios
-------------------
door_open        – hold door_open=True for 8 minutes (240 ticks @ 2 s)
compressor_fail  – gradually raise temp_c by +0.05 °C/tick
gps_jump         – teleport GPS to a random far-away location once
sensor_stuck     – freeze temp_c at a fixed value for 60 ticks
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class DeviceState:
    """Mutable snapshot of a device's current telemetry state."""
    temp_c: float
    humidity: float
    door_open: bool
    battery_v: float
    vibration: float
    lat: float
    lon: float
    # internal counters used by scenarios
    _door_ticks: int = 0
    _stuck_ticks: int = 0
    _stuck_temp: float | None = None
    _gps_jumped: bool = False
    _compressor_fail_active: bool = False


# ---------------------------------------------------------------------------
# Individual scenario handlers
# ---------------------------------------------------------------------------

def _scenario_door_open(state: DeviceState, tick: int, rng: random.Random) -> None:
    """Keep door open for DOOR_OPEN_TICKS ticks, then close."""
    DOOR_OPEN_TICKS = 240   # 480 seconds = 8 minutes at 2 s interval
    if state._door_ticks < DOOR_OPEN_TICKS:
        state.door_open = True
        state._door_ticks += 1
    else:
        state.door_open = False   # scenario exhausted


def _scenario_compressor_fail(state: DeviceState, tick: int, rng: random.Random) -> None:
    """Temperature rises slowly (compressor off)."""
    RISE_PER_TICK = 0.05   # °C per tick
    MAX_RISE = 15.0        # stop rising at nominal + 15 °C
    state._compressor_fail_active = True
    # Drift upward, capped
    state.temp_c = min(state.temp_c + RISE_PER_TICK, state.temp_c + MAX_RISE)


def _scenario_gps_jump(state: DeviceState, tick: int, rng: random.Random) -> None:
    """One-shot GPS teleport to simulate GPS glitch."""
    if not state._gps_jumped:
        # Jump ~500 km away
        state.lat += rng.uniform(3.0, 5.0) * rng.choice([-1, 1])
        state.lon += rng.uniform(3.0, 5.0) * rng.choice([-1, 1])
        state.lat = max(-90.0, min(90.0, state.lat))
        state.lon = max(-180.0, min(180.0, state.lon))
        state._gps_jumped = True


def _scenario_sensor_stuck(state: DeviceState, tick: int, rng: random.Random) -> None:
    """Freeze temperature reading for STUCK_TICKS ticks."""
    STUCK_TICKS = 60
    if state._stuck_temp is None:
        state._stuck_temp = state.temp_c  # latch current value
    if state._stuck_ticks < STUCK_TICKS:
        state.temp_c = state._stuck_temp
        state._stuck_ticks += 1
    else:
        state._stuck_temp = None          # scenario exhausted


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

SCENARIO_REGISTRY: dict[str, Callable[[DeviceState, int, random.Random], None]] = {
    "door_open":       _scenario_door_open,
    "compressor_fail": _scenario_compressor_fail,
    "gps_jump":        _scenario_gps_jump,
    "sensor_stuck":    _scenario_sensor_stuck,
}


def apply_scenarios(
    state: DeviceState,
    scenario_names: list[str],
    tick: int,
    rng: random.Random,
) -> None:
    """Apply each named scenario to the device state in order."""
    for name in scenario_names:
        fn = SCENARIO_REGISTRY.get(name)
        if fn is None:
            raise ValueError(
                f"Unknown scenario {name!r}. "
                f"Valid: {sorted(SCENARIO_REGISTRY)}"
            )
        fn(state, tick, rng)
