"""
Shared utilities for Cold-Chain Sentinel services.

- Structured JSON logging (each log line is a JSON object)
- Simple counter registry (in-process metrics, no Prometheus dependency)
- Env-var helpers
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from collections import defaultdict
from typing import Any


# ---------------------------------------------------------------------------
# Structured JSON logger
# ---------------------------------------------------------------------------

class _JsonFormatter(logging.Formatter):
    """Emit each log record as a single JSON line."""

    SERVICE: str = os.getenv("SERVICE_NAME", "coldchain")

    def format(self, record: logging.LogRecord) -> str:  # noqa: A003
        base: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": record.levelname,
            "service": self.SERVICE,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            base["exc"] = self.formatException(record.exc_info)
        # Attach any extra kwargs passed via logger.info("msg", extra={...})
        for key, val in record.__dict__.items():
            if key.startswith("_") or key in (
                "name", "msg", "args", "created", "filename", "funcName",
                "levelname", "levelno", "lineno", "module", "msecs",
                "message", "pathname", "process", "processName",
                "relativeCreated", "stack_info", "thread", "threadName",
                "exc_info", "exc_text",
            ):
                continue
            base[key] = val
        return json.dumps(base, default=str)


def get_logger(name: str) -> logging.Logger:
    """Return a logger that emits structured JSON to stdout."""
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
        logger.propagate = False
    level_name = os.getenv("LOG_LEVEL", "INFO").upper()
    logger.setLevel(getattr(logging, level_name, logging.INFO))
    return logger


# ---------------------------------------------------------------------------
# In-process metrics counters
# ---------------------------------------------------------------------------

_counters: dict[str, int] = defaultdict(int)
_gauges:   dict[str, float] = {}


def inc(name: str, amount: int = 1) -> None:
    """Increment a named counter."""
    _counters[name] += amount


def set_gauge(name: str, value: float) -> None:
    """Set a named gauge value."""
    _gauges[name] = value


def get_metrics() -> dict[str, Any]:
    """Return a snapshot of all counters and gauges."""
    return {
        "counters": dict(_counters),
        "gauges": dict(_gauges),
    }


# ---------------------------------------------------------------------------
# Env-var helpers
# ---------------------------------------------------------------------------

def require_env(key: str) -> str:
    val = os.getenv(key)
    if not val:
        raise RuntimeError(f"Required environment variable {key!r} is not set.")
    return val


def env_int(key: str, default: int) -> int:
    return int(os.getenv(key, str(default)))


def env_float(key: str, default: float) -> float:
    return float(os.getenv(key, str(default)))


def env_bool(key: str, default: bool = False) -> bool:
    return os.getenv(key, str(default)).lower() in ("1", "true", "yes")
