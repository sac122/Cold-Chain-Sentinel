"""
Cold-Chain Sentinel — IoT Simulator
====================================
Spawns N simulated refrigerated trucks/boxes and publishes JSON telemetry
to coldchain/{device_id}/raw via MQTT.

Usage
-----
    python -m simulator.main [OPTIONS]

    # or via CLI entry-point after pip install:
    coldchain-sim --devices 50 --incident compressor_fail

Options (can also be set via env vars)
---------------------------------------
    --devices  INT          Number of simulated devices  [default: 10]
    --interval FLOAT        Publish interval in seconds  [default: 2.0]
    --seed     INT          RNG seed for determinism     [default: 42]
    --broker   HOST         MQTT broker host             [default: localhost]
    --port     INT          MQTT broker port             [default: 1883]
    --incident TEXT         Scenario to inject; repeatable
                            Choices: door_open | compressor_fail |
                                     gps_jump  | sensor_stuck
    --prefix   TEXT         Device ID prefix             [default: truck]
    --cargo    TEXT         Cargo type (frozen|chilled|ambient) [default: frozen]

Example — 100 devices, all injecting a compressor failure on device-000:
    python -m simulator.main --devices 100 \\
        --incident compressor_fail --seed 1234
"""
from __future__ import annotations

import asyncio
import os
import random
import signal
import sys

import click

# Ensure project root is on path when running directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import aiomqtt

from simulator.config import SimulatorConfig
from simulator.device import DeviceSimulator
from simulator.scenarios import SCENARIO_REGISTRY
from shared.utils import get_logger, get_metrics, inc

log = get_logger("simulator")


# ---------------------------------------------------------------------------
# Device factory
# ---------------------------------------------------------------------------

def build_devices(cfg: SimulatorConfig) -> list[DeviceSimulator]:
    master_rng = random.Random(cfg.RANDOM_SEED)
    devices = []
    for i in range(cfg.NUM_DEVICES):
        device_id = f"{cfg.DEVICE_PREFIX}-{i:03d}"
        lat = master_rng.uniform(cfg.GPS_LAT_MIN, cfg.GPS_LAT_MAX)
        lon = master_rng.uniform(cfg.GPS_LON_MIN, cfg.GPS_LON_MAX)
        # Only device-000 gets injected scenarios so output is predictable
        incidents = cfg.incidents if i == 0 else []
        device_rng = random.Random(cfg.RANDOM_SEED + i * 1000)
        devices.append(DeviceSimulator(
            device_id        = device_id,
            nominal_temp     = cfg.nominal_temp,
            rng              = device_rng,
            publish_interval = cfg.PUBLISH_INTERVAL,
            incidents        = incidents,
            lat              = lat,
            lon              = lon,
        ))
    return devices


# ---------------------------------------------------------------------------
# Metrics printer (background task)
# ---------------------------------------------------------------------------

async def _print_metrics(interval: float = 30.0) -> None:
    while True:
        await asyncio.sleep(interval)
        m = get_metrics()
        log.info("metrics snapshot", extra=m)


# ---------------------------------------------------------------------------
# Main coroutine
# ---------------------------------------------------------------------------

async def run_simulator(cfg: SimulatorConfig) -> None:
    log.info(
        "simulator starting",
        extra={
            "num_devices":    cfg.NUM_DEVICES,
            "broker":         f"{cfg.MQTT_HOST}:{cfg.MQTT_PORT}",
            "interval":       cfg.PUBLISH_INTERVAL,
            "seed":           cfg.RANDOM_SEED,
            "cargo_type":     cfg.CARGO_TYPE,
            "incidents":      cfg.incidents,
        },
    )

    devices = build_devices(cfg)

    # Retry-connect loop — the broker may not be ready immediately
    while True:
        try:
            client_kwargs: dict = {
                "hostname": cfg.MQTT_HOST,
                "port":     cfg.MQTT_PORT,
                "keepalive": 30,
            }
            if cfg.MQTT_USERNAME:
                client_kwargs["username"] = cfg.MQTT_USERNAME
                client_kwargs["password"] = cfg.MQTT_PASSWORD

            async with aiomqtt.Client(**client_kwargs) as client:
                log.info("mqtt connected", extra={"broker": f"{cfg.MQTT_HOST}:{cfg.MQTT_PORT}"})
                inc("sim.connect_ok")

                tasks = [asyncio.create_task(d.run(client)) for d in devices]
                tasks.append(asyncio.create_task(_print_metrics()))

                try:
                    await asyncio.gather(*tasks)
                except asyncio.CancelledError:
                    for t in tasks:
                        t.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    break

        except aiomqtt.MqttError as exc:
            log.warning("mqtt connection failed, retrying in 5 s", extra={"error": str(exc)})
            inc("sim.connect_errors")
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            log.info("simulator shutdown requested")
            break


# ---------------------------------------------------------------------------
# CLI entry-point
# ---------------------------------------------------------------------------

@click.command()
@click.option("--devices",  default=None, type=int,   help="Number of simulated devices")
@click.option("--interval", default=None, type=float, help="Publish interval (seconds)")
@click.option("--seed",     default=None, type=int,   help="RNG seed")
@click.option("--broker",   default=None, type=str,   help="MQTT broker host")
@click.option("--port",     default=None, type=int,   help="MQTT broker port")
@click.option(
    "--incident",
    "incidents",
    multiple=True,
    type=click.Choice(list(SCENARIO_REGISTRY.keys())),
    help="Inject a scenario (repeatable)",
)
@click.option("--prefix",   default=None, type=str,   help="Device ID prefix")
@click.option(
    "--cargo",
    default=None,
    type=click.Choice(["frozen", "chilled", "ambient"]),
    help="Cargo type",
)
def cli(
    devices:   int | None,
    interval:  float | None,
    seed:      int | None,
    broker:    str | None,
    port:      int | None,
    incidents: tuple[str, ...],
    prefix:    str | None,
    cargo:     str | None,
) -> None:
    """Cold-Chain Sentinel IoT Simulator."""
    cfg = SimulatorConfig()
    # CLI flags override env vars
    if devices  is not None: cfg.NUM_DEVICES       = devices
    if interval is not None: cfg.PUBLISH_INTERVAL  = interval
    if seed     is not None: cfg.RANDOM_SEED       = seed
    if broker   is not None: cfg.MQTT_HOST         = broker
    if port     is not None: cfg.MQTT_PORT         = port
    if prefix   is not None: cfg.DEVICE_PREFIX     = prefix
    if cargo    is not None: cfg.CARGO_TYPE        = cargo
    if incidents:
        cfg.INCIDENTS_RAW = ",".join(incidents)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: loop.stop())

    try:
        loop.run_until_complete(run_simulator(cfg))
    except KeyboardInterrupt:
        pass
    finally:
        loop.close()
        log.info("simulator exited")


if __name__ == "__main__":
    cli()
