"""
MQTT topic conventions for Cold-Chain Sentinel.

Layer           Direction           Topic pattern
-----------     --------            ------------------------------------------
Simulator       → Edge              coldchain/{device_id}/raw
Edge            → Fog (telemetry)   coldchain/{device_id}/telemetry
Edge            → Fog (events)      coldchain/{device_id}/events
Fog             → AWS IoT Core      aws/coldchain/{device_id}/telemetry
Fog             → AWS IoT Core      aws/coldchain/{device_id}/events

All traffic flows through a single local Mosquitto broker.
The fog-processor bridges to AWS IoT Core using a separate MQTT connection
(paho-mqtt with mutual TLS to the AWS IoT Core endpoint).
"""

# ── Template strings ─────────────────────────────────────────────────────────

_RAW        = "coldchain/{device_id}/raw"
_TELEMETRY  = "coldchain/{device_id}/telemetry"
_EVENTS     = "coldchain/{device_id}/events"
_AWS_TEL    = "aws/coldchain/{device_id}/telemetry"
_AWS_EVT    = "aws/coldchain/{device_id}/events"

# ── Wildcard subscriptions ────────────────────────────────────────────────────

SUB_ALL_RAW       = "coldchain/+/raw"
SUB_ALL_TELEMETRY = "coldchain/+/telemetry"
SUB_ALL_EVENTS    = "coldchain/+/events"

# ── Factory functions ─────────────────────────────────────────────────────────

def raw(device_id: str) -> str:
    return _RAW.format(device_id=device_id)

def telemetry(device_id: str) -> str:
    return _TELEMETRY.format(device_id=device_id)

def events(device_id: str) -> str:
    return _EVENTS.format(device_id=device_id)

def aws_telemetry(device_id: str) -> str:
    return _AWS_TEL.format(device_id=device_id)

def aws_events(device_id: str) -> str:
    return _AWS_EVT.format(device_id=device_id)

# ── Parsers ───────────────────────────────────────────────────────────────────

def device_id_from_topic(topic: str) -> str:
    """
    Extract device_id from any coldchain/{device_id}/... topic.

    >>> device_id_from_topic("coldchain/truck-042/raw")
    'truck-042'
    """
    parts = topic.split("/")
    if len(parts) < 3 or parts[0] not in ("coldchain", "aws"):
        raise ValueError(f"Unexpected topic format: {topic!r}")
    if parts[0] == "aws":
        # aws/coldchain/{device_id}/...
        return parts[2]
    return parts[1]

def message_kind(topic: str) -> str:
    """Return 'raw', 'telemetry', or 'events' for a coldchain topic."""
    return topic.rsplit("/", 1)[-1]
