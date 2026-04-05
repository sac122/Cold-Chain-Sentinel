"""
Cold-Chain Sentinel — Alert Handler Lambda
==========================================
Triggered by an AWS IoT Topic Rule whenever an event is published to
aws/coldchain/+/events.

Responsibilities
----------------
1. Parse the incoming EventPayload.
2. Write the incident to DynamoDB (incidents table).
3. Publish an SNS alert email for WARNING / CRITICAL severity events.
4. Emit structured CloudWatch log entries.

IAM requirements (see iam.tf)
------------------------------
- dynamodb:PutItem on the incidents table
- sns:Publish on the alerts topic
- logs:CreateLogGroup / logs:PutLogEvents (auto-granted via AWSLambdaBasicExecutionRole)

Environment variables
---------------------
INCIDENTS_TABLE   – DynamoDB table name
SNS_TOPIC_ARN     – SNS topic ARN for alerts
AWS_REGION        – AWS region (set automatically by Lambda runtime)
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3

# ── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# ── AWS clients (initialized outside handler for Lambda reuse) ────────────────

_dynamodb = boto3.client("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))
_sns      = boto3.client("sns",      region_name=os.environ.get("AWS_REGION", "us-east-1"))

INCIDENTS_TABLE = os.environ["INCIDENTS_TABLE"]
SNS_TOPIC_ARN   = os.environ["SNS_TOPIC_ARN"]

# Severity levels that trigger SNS emails
ALERT_SEVERITIES = {"WARNING", "CRITICAL"}

TTL_DAYS = int(os.environ.get("INCIDENT_TTL_DAYS", "90"))


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ANN401
    """
    Lambda handler. IoT Rule passes the MQTT message payload directly as
    the `event` dict (the rule uses SELECT * with no transformation).
    """
    log.info(json.dumps({"msg": "alert_handler invoked", "event_keys": list(event.keys())}))

    try:
        _process_event(event)
        return {"statusCode": 200, "body": "ok"}
    except Exception as exc:
        log.error(json.dumps({"msg": "alert_handler error", "error": str(exc)}))
        raise


def _process_event(payload: dict[str, Any]) -> None:
    device_id  = payload.get("device_id", "unknown")
    event_type = payload.get("event_type", "UNKNOWN")
    severity   = payload.get("severity", "INFO")
    reason     = payload.get("reason", "")
    ts         = payload.get("ts", time.time())
    event_id   = payload.get("event_id", f"evt-{int(ts)}")

    log.info(json.dumps({
        "msg":        "processing event",
        "device_id":  device_id,
        "event_type": event_type,
        "severity":   severity,
    }))

    # 1. Write to DynamoDB ─────────────────────────────────────────────────────
    ttl_epoch = int(ts) + TTL_DAYS * 86400
    item = {
        "device_id":        {"S": device_id},
        "ts_event_id":      {"S": f"{ts:.6f}#{event_id}"},
        "ts":               {"N": str(ts)},
        "event_id":         {"S": event_id},
        "event_type":       {"S": event_type},
        "severity":         {"S": severity},
        "reason":           {"S": reason},
        "telemetry_json":   {"S": json.dumps(payload.get("telemetry", {}))},
        "ttl":              {"N": str(ttl_epoch)},
    }
    if payload.get("anomaly_score") is not None:
        item["anomaly_score"] = {"N": str(payload["anomaly_score"])}
    if payload.get("duration_seconds") is not None:
        item["duration_seconds"] = {"N": str(payload["duration_seconds"])}

    _dynamodb.put_item(TableName=INCIDENTS_TABLE, Item=item)
    log.info(json.dumps({"msg": "incident written to DynamoDB", "event_id": event_id}))

    # 2. SNS alert ─────────────────────────────────────────────────────────────
    if severity in ALERT_SEVERITIES:
        _send_sns_alert(device_id, event_type, severity, reason, ts, event_id, payload)


def _send_sns_alert(
    device_id: str,
    event_type: str,
    severity: str,
    reason: str,
    ts: float,
    event_id: str,
    full_payload: dict[str, Any],
) -> None:
    tel = full_payload.get("telemetry", {})
    subject = f"[{severity}] Cold-Chain Alert: {event_type} on {device_id}"
    body = (
        f"Cold-Chain Sentinel Alert\n"
        f"{'=' * 50}\n\n"
        f"Device:     {device_id}\n"
        f"Event Type: {event_type}\n"
        f"Severity:   {severity}\n"
        f"Timestamp:  {_fmt_ts(ts)}\n"
        f"Event ID:   {event_id}\n\n"
        f"Reason:\n  {reason}\n\n"
        f"Telemetry Snapshot:\n"
        f"  Temperature : {tel.get('temp_c', 'N/A')} °C\n"
        f"  Humidity    : {tel.get('humidity', 'N/A')} %\n"
        f"  Door Open   : {tel.get('door_open', 'N/A')}\n"
        f"  Battery     : {tel.get('battery_v', 'N/A')} V\n"
        f"  GPS         : {tel.get('gps', {})}\n"
        f"  Anomaly Z   : {full_payload.get('anomaly_score', 'N/A')}\n\n"
        f"-- Cold-Chain Sentinel\n"
    )
    _sns.publish(
        TopicArn = SNS_TOPIC_ARN,
        Subject  = subject[:100],   # SNS subject limit
        Message  = body,
    )
    log.info(json.dumps({"msg": "sns alert sent", "subject": subject}))


def _fmt_ts(ts: float) -> str:
    import datetime
    return datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S UTC")
