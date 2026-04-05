"""
Cold-Chain Sentinel — REST API Handler Lambda
==============================================
Serves the API Gateway routes:

  GET  /devices                     – list all known devices (from device registry)
  GET  /incidents                   – list recent incidents (paginated, with filters)
  GET  /devices/{device_id}/summary – last-known telemetry + incident count

Environment variables
---------------------
INCIDENTS_TABLE   – DynamoDB incidents table name
DEVICES_TABLE     – DynamoDB device registry table name
TIMESTREAM_DB     – Timestream database name (optional; for telemetry summary)
TIMESTREAM_TABLE  – Timestream table name (optional)
AWS_REGION        – AWS region
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

_region = os.environ.get("AWS_REGION", "us-east-1")

_ddb_resource  = boto3.resource("dynamodb", region_name=_region)
_ts_query      = boto3.client("timestream-query", region_name=_region)

INCIDENTS_TABLE  = os.environ["INCIDENTS_TABLE"]
DEVICES_TABLE    = os.environ.get("DEVICES_TABLE", "")
TIMESTREAM_DB    = os.environ.get("TIMESTREAM_DB", "")
TIMESTREAM_TABLE = os.environ.get("TIMESTREAM_TABLE", "")

_inc_table = _ddb_resource.Table(INCIDENTS_TABLE)
_dev_table = _ddb_resource.Table(DEVICES_TABLE) if DEVICES_TABLE else None


# ---------------------------------------------------------------------------
# Main router
# ---------------------------------------------------------------------------

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ANN401
    method = event.get("httpMethod") or event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path   = event.get("path") or event.get("rawPath", "/")
    params = event.get("queryStringParameters") or {}
    path_params = event.get("pathParameters") or {}

    log.info(json.dumps({"msg": "api_handler", "method": method, "path": path}))

    try:
        if path == "/devices" and method == "GET":
            return _list_devices(params)
        elif path == "/incidents" and method == "GET":
            return _list_incidents(params)
        elif "/summary" in path and method == "GET":
            device_id = path_params.get("device_id") or path.split("/")[2]
            return _device_summary(device_id, params)
        else:
            return _resp(404, {"error": f"Not found: {method} {path}"})
    except Exception as exc:
        log.error(json.dumps({"msg": "api error", "error": str(exc)}))
        return _resp(500, {"error": "Internal server error", "detail": str(exc)})


# ---------------------------------------------------------------------------
# GET /devices
# ---------------------------------------------------------------------------

def _list_devices(params: dict) -> dict:
    if _dev_table is None:
        return _resp(503, {"error": "Device registry table not configured"})
    resp = _dev_table.scan(Limit=200)
    devices = resp.get("Items", [])
    return _resp(200, {
        "devices": devices,
        "count":   len(devices),
    })


# ---------------------------------------------------------------------------
# GET /incidents
# ---------------------------------------------------------------------------

def _list_incidents(params: dict) -> dict:
    device_id = params.get("device_id")
    severity  = params.get("severity")
    limit     = int(params.get("limit", "50"))
    limit     = min(limit, 200)

    if device_id:
        resp = _inc_table.query(
            KeyConditionExpression=Key("device_id").eq(device_id),
            ScanIndexForward=False,   # newest first
            Limit=limit,
        )
    else:
        # Full scan for now; add a GSI on ts for production
        resp = _inc_table.scan(Limit=limit)

    items = resp.get("Items", [])

    if severity:
        items = [i for i in items if i.get("severity") == severity.upper()]

    # Sort by ts descending
    items.sort(key=lambda x: float(x.get("ts", 0)), reverse=True)

    return _resp(200, {
        "incidents": items,
        "count":     len(items),
    })


# ---------------------------------------------------------------------------
# GET /devices/{device_id}/summary
# ---------------------------------------------------------------------------

def _device_summary(device_id: str, params: dict) -> dict:
    # Last 3 incidents
    try:
        inc_resp = _inc_table.query(
            KeyConditionExpression=Key("device_id").eq(device_id),
            ScanIndexForward=False,
            Limit=3,
        )
        recent_incidents = inc_resp.get("Items", [])
    except Exception as exc:
        log.warning(json.dumps({"msg": "incident query error", "error": str(exc)}))
        recent_incidents = []

    # Last telemetry from Timestream (if configured)
    last_telemetry = None
    if TIMESTREAM_DB and TIMESTREAM_TABLE:
        last_telemetry = _query_last_telemetry(device_id)

    return _resp(200, {
        "device_id":        device_id,
        "recent_incidents": recent_incidents,
        "last_telemetry":   last_telemetry,
        "incident_count":   len(recent_incidents),
    })


def _query_last_telemetry(device_id: str) -> dict | None:
    query = (
        f"SELECT * FROM \"{TIMESTREAM_DB}\".\"{TIMESTREAM_TABLE}\" "
        f"WHERE device_id = '{device_id}' "
        f"ORDER BY time DESC LIMIT 1"
    )
    try:
        resp = _ts_query.query(QueryString=query)
        rows = resp.get("Rows", [])
        cols = [c["Name"] for c in resp.get("ColumnInfo", [])]
        if rows:
            return dict(zip(cols, [_extract_ts_val(d) for d in rows[0]["Data"]]))
    except Exception as exc:
        log.warning(json.dumps({"msg": "timestream query error", "error": str(exc)}))
    return None


def _extract_ts_val(datum: dict) -> str:
    return (
        datum.get("ScalarValue")
        or datum.get("NullValue")
        or ""
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resp(status_code: int, body: Any) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }
