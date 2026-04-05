# Cold-Chain Sentinel

**Edge + Fog anomaly detection for cold-chain logistics using MQTT + AWS**

A production-ready, end-to-end IoT system that monitors refrigerated trucks
and storage boxes, detects anomalies at the edge, and forwards incidents to
AWS for storage, alerting, and visualization.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  DEVICE LAYER  (Python asyncio simulator)                                │
│                                                                          │
│  truck-000  truck-001  ...  truck-N                                      │
│  temp_c  humidity  door_open  battery_v  gps  vibration                  │
│         │ coldchain/{id}/raw  (MQTT QoS 0, 2 s interval)                │
└─────────┼────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  EDGE LAYER  (edge-processor container)                                  │
│                                                                          │
│  ┌─────────────────────────┐   ┌────────────────────────────────────┐   │
│  │  Rules Engine           │   │  EWMA Anomaly Detector             │   │
│  │  • TEMP_EXCURSION       │   │  • α = 0.1 smoothing factor        │   │
│  │  • DOOR_OPEN_TOO_LONG   │   │  • z-score = (x − ewma) / σ       │   │
│  │  • BATTERY_LOW          │   │  • fires when |z| > 3.0            │   │
│  │  • SENSOR_STUCK         │   │                                    │   │
│  │  • GPS_JUMP             │   └────────────────────────────────────┘   │
│  └─────────────────────────┘                                            │
│         │                                                                │
│  coldchain/{id}/telemetry  (1-in-10 downsampled, EWMA-annotated)         │
│  coldchain/{id}/events     (all rule violations + anomalies, QoS 1)     │
└─────────┼────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  FOG LAYER  (Mosquitto + fog-processor container)                        │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Eclipse Mosquitto 2.0 MQTT Broker                                │  │
│  │  Listens: 1883 (plain) · 9001 (WebSocket)                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  fog-processor (FastAPI + asyncio)                                │  │
│  │  • Subscribes to coldchain/+/telemetry, coldchain/+/events        │  │
│  │  • Forwards to aws/coldchain/{id}/telemetry|events via TLS/MQTT   │  │
│  │  • SQLite disk-backed buffer (offline tolerance)                  │  │
│  │  • Metrics API: GET /health  /metrics  /buffer                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│         │ paho-mqtt + TLS (port 8883)                                    │
└─────────┼────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CLOUD LAYER  (AWS Managed Services)                                     │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  AWS IoT Core                                                │       │
│  │  aws/coldchain/+/telemetry  →  Topic Rule → Timestream       │       │
│  │  aws/coldchain/+/events     →  Topic Rule → Lambda (alert)   │       │
│  └──────────────────────────────────────────────────────────────┘       │
│         │                          │                                     │
│         ▼                          ▼                                     │
│  ┌──────────────┐         ┌──────────────────────────────────┐          │
│  │  Timestream  │         │  Lambda: alert_handler           │          │
│  │  (telemetry) │         │  • writes incident to DynamoDB   │          │
│  │  memory: 24h │         │  • publishes SNS alert email     │          │
│  │  magnetic:90d│         └───────────────┬──────────────────┘          │
│  └──────────────┘                         │                             │
│                                           ▼                             │
│                              ┌────────────────────────┐                 │
│                              │  DynamoDB              │                 │
│                              │  coldchain-incidents   │                 │
│                              │  coldchain-devices     │                 │
│                              └────────────┬───────────┘                 │
│                                           │ DynamoDB Streams            │
│                                           ▼                             │
│                              ┌────────────────────────┐                 │
│                              │  Lambda: stream_proc   │                 │
│                              │  Updates device registry│                │
│                              └────────────────────────┘                 │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  API Gateway (HTTP API) + Lambda: api_handler                │       │
│  │  GET /devices            – list all registered devices       │       │
│  │  GET /incidents          – recent incidents (filterable)     │       │
│  │  GET /devices/{id}/summary – last telemetry + incidents      │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  ECS Fargate                                                 │       │
│  │  • fog-processor service  (bridges local fog → IoT Core)    │       │
│  │  • grafana service        (Grafana OSS + Timestream plugin)  │       │
│  └──────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
cold-chain-sentinel/
├── shared/                     # Common library (schemas, topics, utils)
│   ├── schemas.py              # Pydantic v2 TelemetryPayload + EventPayload
│   ├── topics.py               # MQTT topic conventions
│   └── utils.py                # JSON logger, metrics, env helpers
│
├── simulator/                  # IoT Device Simulator
│   ├── main.py                 # CLI entry-point; asyncio event loop
│   ├── device.py               # Per-device physics model + MQTT publisher
│   ├── scenarios.py            # Scenario injection (door_open, compressor_fail…)
│   ├── config.py               # Environment-variable config
│   ├── requirements.txt
│   └── Dockerfile
│
├── edge/                       # Edge Processor
│   ├── main.py                 # asyncio MQTT subscriber + dispatcher
│   ├── rules.py                # Rules-based detection (5 rules, stateful)
│   ├── anomaly.py              # EWMA + z-score anomaly detection
│   ├── config.py
│   ├── requirements.txt
│   └── Dockerfile
│
├── fog/
│   ├── mosquitto/
│   │   ├── mosquitto.conf      # Broker config (plain, local dev)
│   │   └── mosquitto-tls.conf  # Broker config (TLS, production)
│   └── fog-processor/
│       ├── main.py             # FastAPI + asyncio MQTT subscriber
│       ├── buffer.py           # SQLite disk-backed offline queue
│       ├── aws_bridge.py       # paho-mqtt TLS → AWS IoT Core
│       ├── config.py
│       ├── requirements.txt
│       └── Dockerfile
│
├── cloud/
│   ├── lambdas/
│   │   ├── alert_handler/      # IoT rule → DynamoDB + SNS
│   │   ├── api_handler/        # API Gateway → DynamoDB + Timestream
│   │   └── stream_processor/   # DynamoDB Streams → device registry
│   └── terraform/
│       ├── main.tf             # Provider, backend, data sources
│       ├── variables.tf        # All input variables
│       ├── outputs.tf          # Key outputs (endpoints, ARNs, next steps)
│       ├── iot.tf              # IoT Thing, Certificate, Policy, Topic Rules
│       ├── dynamodb.tf         # incidents + devices tables (with TTL, streams)
│       ├── timestream.tf       # Telemetry time-series database
│       ├── sns.tf              # Alert topic + email subscription
│       ├── iam.tf              # Least-privilege roles (Lambda, ECS, IoT)
│       ├── lambda.tf           # 3 Lambda functions + event source mapping
│       ├── api_gateway.tf      # HTTP API v2 with 3 routes
│       ├── ecr.tf              # ECR repos + lifecycle policies
│       ├── ecs.tf              # ECS cluster + Fargate services
│       └── cloudwatch.tf       # Log groups, alarms, dashboard
│
├── grafana/
│   └── provisioning/
│       ├── datasources/        # Timestream + FogProcessor datasources
│       └── dashboards/         # Fleet temperature + anomaly dashboard
│
├── docker-compose.yml          # Local development stack
├── docker-compose.aws.yml      # AWS overlay (adds TLS certs + endpoint)
├── .env.example                # Environment variable template
├── Makefile                    # All common tasks (up, push, deploy, etc.)
├── aws_setup.sh                # Automated AWS provisioning script
├── local_run.md                # Local development guide
├── aws_runbook.md              # AWS deployment runbook
└── demo_script.md              # 5-minute demo walkthrough
```

---

## Data Contracts

### TelemetryPayload (coldchain/{id}/raw and /telemetry)

```json
{
  "device_id": "truck-042",
  "ts": 1717200000.123,
  "seq": 1234,
  "gps": { "lat": 37.8044, "lon": -122.2712 },
  "temp_c": -17.834,
  "humidity": 84.2,
  "door_open": false,
  "battery_v": 12.41,
  "vibration": 0.234,
  "anomaly_score": 1.23,
  "ewma_temp": -17.91,
  "edge_processed": true
}
```

### EventPayload (coldchain/{id}/events)

```json
{
  "device_id": "truck-042",
  "ts": 1717200120.456,
  "event_id": "a3b2c1d0-...",
  "event_type": "TEMP_EXCURSION",
  "severity": "CRITICAL",
  "reason": "Temperature -13.87 °C exceeded -15.0 °C for 3 consecutive readings",
  "anomaly_score": 4.23,
  "duration_seconds": null,
  "prev_gps": null,
  "telemetry": { "...": "snapshot at event time" }
}
```

**Event types:** `TEMP_EXCURSION` · `DOOR_OPEN_TOO_LONG` · `BATTERY_LOW` ·
`SENSOR_STUCK` · `ANOMALY` · `GPS_JUMP` · `COMPRESSOR_FAIL`

**Severity levels:** `INFO` · `WARNING` · `CRITICAL`

---

## MQTT Topic Conventions

| Layer | Direction | Topic |
|-------|-----------|-------|
| Simulator → Edge | publish | `coldchain/{device_id}/raw` |
| Edge → Fog | publish | `coldchain/{device_id}/telemetry` (1-in-10) |
| Edge → Fog | publish | `coldchain/{device_id}/events` |
| Fog → AWS IoT Core | publish | `aws/coldchain/{device_id}/telemetry` |
| Fog → AWS IoT Core | publish | `aws/coldchain/{device_id}/events` |

---

## Design Decisions

### DynamoDB (incidents) vs Timestream (telemetry)

| Concern | DynamoDB | Timestream |
|---------|----------|-----------|
| Volume | Low (events only) | High (all telemetry) |
| Access pattern | Lookup by device + time range | Time-range aggregations (AVG, BIN) |
| Cost at scale | Higher for dense time-series | ~90% cheaper for dense time-series |
| Query flexibility | Rich (GSI, filter expressions) | Time-series SQL (INTERPOLATE, etc.) |
| Grafana plugin | Available | Native, purpose-built |

Incidents in DynamoDB, telemetry in Timestream.

### ECS Fargate vs EKS

ECS Fargate is chosen for the fog-processor and Grafana because:
- The workload is 1-2 long-running services — Kubernetes is over-engineered
- ECS Fargate is fully serverless (no EC2 to manage)
- Lower cost and simpler IAM/networking
- EKS adds ~$0.10/hr control-plane cost plus node management

### Edge Anomaly Detection: EWMA + Z-score

EWMA is chosen over river/sklearn/PyTorch because:
- Zero external ML dependencies (runs on constrained edge hardware)
- Online learning — no training phase, adapts to seasonal patterns
- Explainable: z-score maps to standard deviations above the moving average
- 3 floats per device: ewma, variance, n_samples — trivial memory footprint

---

## Quickstart

```bash
# Local (no AWS required)
cp .env.example .env
make up        # Start all services
make sim-run   # Run 10-device simulator

# Inject a scenario
make sim-incident  # Compressor failure on device-000

# Check metrics
make smoke-test

# AWS deployment
export ALERT_EMAIL=you@example.com
./aws_setup.sh
```

See [local_run.md](local_run.md) and [aws_runbook.md](aws_runbook.md) for full details.

---

## Security Notes

- IoT certificates stored in AWS SSM Parameter Store (SecureString / KMS-encrypted)
- IoT policy scoped to `aws/coldchain/*` topics and specific client ID prefix
- Lambda functions have least-privilege inline policies (no wildcard actions)
- No secrets in source code; all configuration via environment variables
- ECR image scanning enabled on push
- DynamoDB point-in-time recovery enabled

---

## License

MIT
