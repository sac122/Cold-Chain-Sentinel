"""
Cold-Chain Sentinel — DynamoDB Stream Processor Lambda
=======================================================
Triggered by DynamoDB Streams on the incidents table.

Responsibilities
----------------
- Upserts a device record into the device registry table whenever a
  new incident arrives (keeps last_seen, last_event_type, last_severity).
- Can be extended to aggregate incident counts, trigger escalations, etc.

Environment variables
---------------------
DEVICES_TABLE   – DynamoDB device registry table name
AWS_REGION      – AWS region
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

_region    = os.environ.get("AWS_REGION", "us-east-1")
_ddb       = boto3.resource("dynamodb", region_name=_region)
DEVICES_TABLE = os.environ.get("DEVICES_TABLE", "")

_dev_table = _ddb.Table(DEVICES_TABLE) if DEVICES_TABLE else None


def handler(event: dict[str, Any], context: Any) -> None:  # noqa: ANN401
    if not _dev_table:
        log.warning("DEVICES_TABLE not set — stream processor skipping device upsert")
        return

    for record in event.get("Records", []):
        if record.get("eventName") != "INSERT":
            continue
        new_image = record.get("dynamodb", {}).get("NewImage", {})
        _upsert_device(new_image)


def _upsert_device(image: dict[str, Any]) -> None:
    device_id  = _s(image, "device_id")
    event_type = _s(image, "event_type")
    severity   = _s(image, "severity")
    ts_str     = _n(image, "ts")

    if not device_id:
        return

    try:
        _dev_table.update_item(
            Key={"device_id": device_id},
            UpdateExpression=(
                "SET last_seen = :ts, "
                "    last_event_type = :et, "
                "    last_severity = :sev, "
                "    updated_at = :now"
            ),
            ExpressionAttributeValues={
                ":ts":  ts_str,
                ":et":  event_type,
                ":sev": severity,
                ":now": str(time.time()),
            },
        )
        log.info(json.dumps({
            "msg":        "device upserted",
            "device_id":  device_id,
            "event_type": event_type,
        }))
    except Exception as exc:
        log.error(json.dumps({"msg": "device upsert error", "error": str(exc)}))


def _s(image: dict, key: str) -> str:
    return image.get(key, {}).get("S", "")

def _n(image: dict, key: str) -> str:
    return image.get(key, {}).get("N", "0")
