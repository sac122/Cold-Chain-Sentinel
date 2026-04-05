"""
Individual device simulator.

Each DeviceSimulator runs as an asyncio task, publishing JSON telemetry
to coldchain/{device_id}/raw at a configurable interval.

Physics model
-------------
- Temperature: sinusoidal oscillation around nominal setpoint (± 1 °C
  amplitude, 5-minute period) plus Gaussian noise (σ = 0.3 °C).
- Humidity: random walk around 85 %, clamped [60, 99].
- Door: opens for ~30 s once every ~20 minutes on average.
- Battery: slow linear drain from 12.6 V → 11.0 V over 8 h, then resets.
- Vibration: base 0.2 m/s² with random spikes.
- GPS: slow random walk (simulates a moving truck).
"""
from __future__ import annotations

import asyncio
import json
import math
import random
import time
from typing import Optional

import aiomqtt

from simulator.scenarios import DeviceState, apply_scenarios
from shared.schemas import GPSCoord, TelemetryPayload
from shared.topics import raw as raw_topic
from shared.utils import get_logger, inc

log = get_logger(__name__)


class DeviceSimulator:
    """Simulates a single refrigerated truck / cold-storage box."""

    # Battery cycle: drain over BATTERY_CYCLE_TICKS, then reset
    BATTERY_CYCLE_TICKS = int(8 * 3600 / 2)   # 8 hours at 2 s/tick

    def __init__(
        self,
        device_id: str,
        nominal_temp: float,
        rng: random.Random,
        publish_interval: float,
        incidents: list[str],
        lat: float,
        lon: float,
    ) -> None:
        self.device_id       = device_id
        self.nominal_temp    = nominal_temp
        self.rng             = rng
        self.publish_interval= publish_interval
        self.incidents       = incidents

        # Mutable device state
        self.state = DeviceState(
            temp_c    = nominal_temp + rng.uniform(-0.5, 0.5),
            humidity  = rng.uniform(80.0, 90.0),
            door_open = False,
            battery_v = rng.uniform(12.2, 12.6),
            vibration = 0.2,
            lat       = lat,
            lon       = lon,
        )

        self._tick          = 0
        self._seq           = 0
        self._door_open_since: Optional[float] = None
        self._phase_offset   = rng.uniform(0, 2 * math.pi)

    # ── Physics update ────────────────────────────────────────────────────────

    def _update_state(self) -> None:
        t = self._tick
        rng = self.rng

        # Temperature: sinusoidal + noise
        period = 150   # ticks (~5 min)
        self.state.temp_c = (
            self.nominal_temp
            + math.sin(2 * math.pi * t / period + self._phase_offset) * 1.0
            + rng.gauss(0, 0.3)
        )

        # Humidity: bounded random walk
        self.state.humidity = max(60.0, min(99.0,
            self.state.humidity + rng.gauss(0, 0.5)
        ))

        # Door: open ~30 s once every 20 min on average (Poisson process)
        if not self.state.door_open:
            # Probability of opening this tick ≈ 1 / (20*60/2) ≈ 0.0017
            if rng.random() < 0.0017:
                self.state.door_open = True
                self._door_open_since = time.time()
        else:
            # Close after 15 ticks (~30 s)
            elapsed = time.time() - (self._door_open_since or time.time())
            if elapsed > 30:
                self.state.door_open = False
                self._door_open_since = None

        # Battery: linear drain, reset at cycle boundary
        cycle_pos = t % self.BATTERY_CYCLE_TICKS
        self.state.battery_v = 12.6 - (cycle_pos / self.BATTERY_CYCLE_TICKS) * 1.6

        # Vibration: base + occasional spikes
        self.state.vibration = 0.2 + abs(rng.gauss(0, 0.1))
        if rng.random() < 0.02:       # 2 % chance of a bump
            self.state.vibration += rng.uniform(1.0, 4.0)

        # GPS: slow random walk (≈ 50 m per tick at vehicle speed)
        self.state.lat += rng.gauss(0, 0.00005)
        self.state.lon += rng.gauss(0, 0.00005)

        # Apply injected scenarios (they can override any of the above)
        apply_scenarios(self.state, self.incidents, t, rng)

        self._tick += 1
        self._seq  += 1

    # ── Message construction ──────────────────────────────────────────────────

    def _build_payload(self) -> TelemetryPayload:
        s = self.state
        return TelemetryPayload(
            device_id = self.device_id,
            ts        = time.time(),
            gps       = GPSCoord(lat=s.lat, lon=s.lon),
            temp_c    = round(s.temp_c, 3),
            humidity  = round(s.humidity, 2),
            door_open = s.door_open,
            battery_v = round(s.battery_v, 3),
            vibration = round(s.vibration, 4),
            seq       = self._seq,
        )

    # ── Main run loop ─────────────────────────────────────────────────────────

    async def run(self, client: aiomqtt.Client) -> None:
        """Publish telemetry forever. Pass the shared aiomqtt Client."""
        topic = raw_topic(self.device_id)
        log.info("device started", extra={"device_id": self.device_id, "topic": topic})

        while True:
            try:
                start = asyncio.get_event_loop().time()
                self._update_state()
                payload = self._build_payload()
                await client.publish(
                    topic,
                    payload=payload.model_dump_json(),
                    qos=0,
                )
                inc("sim.messages_published")
                log.debug(
                    "published",
                    extra={
                        "device_id": self.device_id,
                        "seq": self._seq,
                        "temp_c": payload.temp_c,
                        "door_open": payload.door_open,
                    },
                )
                elapsed = asyncio.get_event_loop().time() - start
                await asyncio.sleep(max(0.0, self.publish_interval - elapsed))
            except aiomqtt.MqttError as exc:
                log.warning("mqtt error", extra={"device_id": self.device_id, "error": str(exc)})
                inc("sim.mqtt_errors")
                await asyncio.sleep(5)
            except asyncio.CancelledError:
                log.info("device stopped", extra={"device_id": self.device_id})
                return
            except Exception as exc:  # noqa: BLE001
                log.error("unexpected error", extra={"device_id": self.device_id, "error": str(exc)})
                inc("sim.errors")
                await asyncio.sleep(1)
