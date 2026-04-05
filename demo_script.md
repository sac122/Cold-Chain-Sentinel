# 5-Minute Demo Script — Cold-Chain Sentinel

A step-by-step walkthrough to demonstrate the full system working end-to-end.
Start with services already running (`make up` completed).

---

## Setup (before the demo — 2 minutes)

```bash
# Start the stack
make up

# Wait for healthy status
docker compose ps
# All services should show "healthy" or "running"

# Open a second terminal for MQTT monitoring
docker compose exec mosquitto mosquitto_sub \
    -t "coldchain/+/events" \
    -t "coldchain/+/telemetry" \
    -v &
```

Open browser tabs:
- `http://localhost:3000` — Grafana (admin/coldchain123)
- `http://localhost:8080/metrics` — Fog metrics

---

## Demo Step 1 — Normal Operation (30 seconds)

**What to show:** Telemetry flowing through the pipeline.

```bash
# Watch raw MQTT traffic
docker compose exec mosquitto mosquitto_sub \
    -t "coldchain/+/raw" -v -C 5
```

Point out:
- Simulator generates `coldchain/truck-001/raw` every 2 seconds
- JSON payload: `device_id`, `ts`, `gps`, `temp_c` (~-18°C), `door_open: false`, `battery_v` (~12.5V)

```bash
# Watch edge output — 1-in-10 downsampled + EWMA annotation
docker compose exec mosquitto mosquitto_sub \
    -t "coldchain/+/telemetry" -v -C 3
```

Point out:
- Fog receives this and would forward to AWS IoT Core if connected
- Check metrics: `curl -s localhost:8080/metrics | python3 -m json.tool`

---

## Demo Step 2 — Compressor Failure (90 seconds)

**What to show:** Rules-based detection catching a temperature excursion.

```bash
# In a new terminal, inject compressor failure on device-000
docker compose run --rm \
    -e INCIDENTS=compressor_fail \
    -e NUM_DEVICES=3 \
    simulator python -m simulator.main --seed 99
```

Watch the MQTT monitor terminal — within ~30-60 seconds you'll see:

```json
coldchain/truck-000/events {
  "device_id": "truck-000",
  "event_type": "TEMP_EXCURSION",
  "severity": "CRITICAL",
  "reason": "Temperature -14.87 °C exceeded -15.0 °C for 3 consecutive readings",
  "anomaly_score": 4.23
}
```

Point out:
- Edge processed 3 consecutive above-threshold readings → fired event
- EWMA z-score > 3.0 also fired an `ANOMALY` event
- In AWS mode, this would → Lambda → DynamoDB → SNS email

---

## Demo Step 3 — Door Open Too Long (60 seconds)

**What to show:** Stateful rule engine tracking duration.

```bash
# Stop previous simulator, start door_open scenario
docker compose run --rm \
    -e INCIDENTS=door_open \
    -e NUM_DEVICES=3 \
    simulator python -m simulator.main --seed 1
```

The default door-open alert fires after 300 seconds (5 minutes).
For the demo, temporarily lower the threshold:

```bash
# Override threshold to 30 seconds for demo speed
docker compose run --rm \
    -e INCIDENTS=door_open \
    -e NUM_DEVICES=3 \
    -e EDGE_DOOR_OPEN_SECONDS=30 \
    edge  # just to show the env var exists
```

Restart edge with lower threshold:
```bash
docker compose stop edge
docker compose run --rm \
    -e MQTT_HOST=mosquitto \
    -e EDGE_DOOR_OPEN_SECONDS=30 \
    edge python -m edge.main &
```

Within ~30 seconds:
```json
coldchain/truck-000/events {
  "event_type": "DOOR_OPEN_TOO_LONG",
  "severity": "WARNING",
  "reason": "Cargo door open for 32 s (threshold 30 s)",
  "duration_seconds": 32.1
}
```

---

## Demo Step 4 — GPS Jump (10 seconds)

**What to show:** Instant anomaly detection on a single reading.

```bash
docker compose run --rm \
    -e INCIDENTS=gps_jump \
    -e NUM_DEVICES=3 \
    simulator python -m simulator.main --seed 5
```

Within 2 seconds of the first publish:
```json
coldchain/truck-000/events {
  "event_type": "GPS_JUMP",
  "severity": "WARNING",
  "reason": "GPS position jumped 412.3 km in one tick (threshold 50.0 km)",
  "prev_gps": {"lat": 37.82, "lon": -122.41}
}
```

---

## Demo Step 5 — Offline Buffering (30 seconds)

**What to show:** Fog buffer handles AWS connectivity loss gracefully.

In `docker-compose.aws.yml` mode, disconnect AWS by setting a bad endpoint:

```bash
# Show buffer filling up (simulate AWS unreachable)
docker compose stop fog-processor
docker compose run --rm \
    -e AWS_IOT_ENDPOINT=bad-endpoint.invalid \
    -e MQTT_HOST=mosquitto \
    fog-processor python -m fog.fog_processor.main &

sleep 15

# Check buffer depth
curl -s localhost:8080/buffer | python3 -m json.tool
# Expected: {"size": N, "max_size": 10000, "pct_full": 0.X}
```

Restore connectivity:
```bash
# Restore fog processor
docker compose up -d fog-processor

# Buffer drains automatically within 10 seconds (BUFFER_FLUSH_INTERVAL)
watch -n 2 'curl -s localhost:8080/buffer'
```

---

## Demo Step 6 — Fog Metrics (10 seconds)

```bash
curl -s http://localhost:8080/metrics | python3 -m json.tool
```

Show counters:
- `fog.messages_received`: total messages from local broker
- `fog.messages_forwarded`: forwarded to AWS
- `fog.messages_buffered`: queued due to AWS unavailability
- `fog.buffer_flushed`: replayed from buffer
- `edge.events_published`: anomalies + rule violations detected

---

## Summary Talking Points

| Layer | Technology | Key Feature Shown |
|-------|-----------|-------------------|
| Device/Simulator | Python asyncio + aiomqtt | 10+ concurrent devices, scenario injection |
| Edge | EWMA z-score + rules engine | Temp excursion, door timer, GPS jump |
| Fog | SQLite queue + paho-mqtt TLS | Offline buffering, AWS bridge |
| Cloud | IoT Core → Lambda → DynamoDB | Serverless event-driven pipeline |
| Observability | Structured JSON logs + CW | Real-time metrics, dashboards |

**Architecture flow:**
```
Simulator ──MQTT──▶ [Mosquitto] ──▶ Edge Processor
                                         │
                              ┌──────────┴──────────┐
                              ▼                     ▼
                        telemetry (1/10)        events (all)
                              │                     │
                              └──────────┬──────────┘
                                         ▼
                                   Fog Processor
                                   (SQLite buffer)
                                         │ TLS/MQTT
                                         ▼
                                  AWS IoT Core
                                  ┌──────┴───────┐
                                  ▼              ▼
                              Timestream      Lambda
                              (telemetry)   (alert)
                                              │
                                    ┌─────────┴──────┐
                                    ▼                ▼
                                DynamoDB            SNS
                               (incidents)        (email)
```
