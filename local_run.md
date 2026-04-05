# Local Run Guide — Cold-Chain Sentinel

Run the entire Cold-Chain Sentinel stack on your laptop with a single command.
No AWS account needed for local mode.

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker Desktop | 4.x | https://docs.docker.com/get-docker/ |
| docker compose | 2.x (bundled) | included with Docker Desktop |
| Python 3.11 | optional | only for running services directly (no Docker) |

## Quick Start (Docker Compose)

```bash
# 1. Clone repo and enter project directory
cd cold-chain-sentinel

# 2. Copy environment template
cp .env.example .env
# Leave AWS_IOT_ENDPOINT empty for local-only mode

# 3. Start the full stack
make up
# or:
docker compose up -d

# 4. Follow logs (optional)
make logs
# or:
docker compose logs -f
```

After ~20 seconds all services should be healthy.

### Services running

| Service | Port | URL |
|---------|------|-----|
| Mosquitto MQTT | 1883 | `mqtt://localhost:1883` |
| Mosquitto WS | 9001 | `ws://localhost:9001` |
| Fog Processor API | 8080 | `http://localhost:8080` |
| Grafana | 3000 | `http://localhost:3000` |

Grafana credentials: `admin` / `coldchain123`

## Verify the System is Working

### 1. Check service health

```bash
make smoke-test
# or manually:
curl -s http://localhost:8080/health | python3 -m json.tool
```

Expected output:
```json
{
    "status": "ok",
    "aws_connected": false,
    "aws_enabled": false,
    "buffer_size": 0
}
```

### 2. Watch MQTT traffic

Install [MQTT Explorer](http://mqtt-explorer.com/) and connect to `localhost:1883`,
or use mosquitto_sub from the container:

```bash
# Subscribe to all raw telemetry
docker compose exec mosquitto mosquitto_sub -t "coldchain/+/raw" -v

# Subscribe to events only
docker compose exec mosquitto mosquitto_sub -t "coldchain/+/events" -v

# Subscribe to edge-processed telemetry
docker compose exec mosquitto mosquitto_sub -t "coldchain/+/telemetry" -v
```

### 3. Verify metrics counters

```bash
curl -s http://localhost:8080/metrics | python3 -m json.tool
```

Look for increasing counters:
- `sim.messages_published` — simulator publishing
- `edge.messages_received` — edge receiving raw messages
- `edge.telemetry_forwarded` — 1-in-10 forwarded
- `edge.events_published` — any anomalies/rules triggered
- `fog.messages_received` — fog receiving telemetry/events

## Inject Scenarios

Scenarios are injected on `device-000` only (device index 0).

### Door open too long

```bash
docker compose run --rm -e INCIDENTS=door_open simulator \
    python -m simulator.main --devices 5
```

After ~5 minutes (`EDGE_DOOR_OPEN_SECONDS=300`), watch for:
```
coldchain/truck-000/events  → {"event_type": "DOOR_OPEN_TOO_LONG", "severity": "WARNING", ...}
```

### Compressor failure (temperature rise)

```bash
docker compose run --rm -e INCIDENTS=compressor_fail simulator \
    python -m simulator.main --devices 5
```

Temperature on device-000 rises +0.05 °C/tick.  After a few minutes
the edge processor fires `TEMP_EXCURSION` events.

### GPS jump

```bash
docker compose run --rm -e INCIDENTS=gps_jump simulator \
    python -m simulator.main --devices 5
```

Device-000's GPS teleports ~400 km away on the first tick.
Edge fires `GPS_JUMP` event immediately.

### Sensor stuck

```bash
docker compose run --rm -e INCIDENTS=sensor_stuck simulator \
    python -m simulator.main --devices 5
```

Temperature freezes for 60 ticks (~2 minutes).
Edge fires `SENSOR_STUCK` event once the window fills.

### Multiple incidents simultaneously

```bash
docker compose run --rm -e INCIDENTS=door_open,compressor_fail simulator \
    python -m simulator.main --devices 5
```

### Deterministic replay

```bash
# Always produces identical output — useful for demos
docker compose run --rm simulator python -m simulator.main \
    --devices 10 --seed 42 --incident compressor_fail
```

## Scale up to 100 devices

```bash
docker compose run --rm -e NUM_DEVICES=100 simulator \
    python -m simulator.main
```

100 async tasks with 2-second intervals = ~50 msgs/s.
This runs comfortably on a modern laptop (CPU usage < 5%).

## View Grafana Dashboard

1. Open `http://localhost:3000`
2. Login: `admin` / `coldchain123`
3. Navigate to **Dashboards → Cold-Chain → Fleet Overview**

> Note: The Grafana Timestream plugin requires AWS credentials.
> In local mode, the dashboards show the data source as unavailable —
> this is expected.  In AWS mode, configure the datasource with your region.

## Run Services Directly (without Docker)

```bash
# Terminal 1: Mosquitto
docker run --rm -p 1883:1883 -p 9001:9001 \
    -v $(pwd)/fog/mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf \
    eclipse-mosquitto:2.0

# Terminal 2: Edge processor
cd cold-chain-sentinel
pip install -r edge/requirements.txt
MQTT_HOST=localhost python -m edge.main

# Terminal 3: Fog processor
pip install -r fog/fog-processor/requirements.txt
MQTT_HOST=localhost python -m fog.fog_processor.main

# Terminal 4: Simulator
pip install -r simulator/requirements.txt
MQTT_HOST=localhost python -m simulator.main --devices 5
```

## Stop Everything

```bash
make down
# or:
docker compose down
# Remove volumes too:
docker compose down -v
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Port 1883 already in use | `sudo lsof -i :1883` and kill the process |
| Edge not receiving messages | Check mosquitto is healthy: `docker compose ps` |
| Fog shows 0 messages | Ensure edge is running and publishing to telemetry/events |
| Grafana can't connect | Check fog-processor is on port 8080: `curl localhost:8080/health` |
| ImportError on `aiomqtt` | Rebuild image: `docker compose build edge simulator` |
