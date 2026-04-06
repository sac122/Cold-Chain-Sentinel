"""
WebSocket connection manager.

Keeps a set of live WebSocket connections and broadcasts JSON messages
to all of them, silently removing any that have disconnected.
"""
from __future__ import annotations

import asyncio
import json
from typing import Any

from fastapi import WebSocket

from shared.utils import get_logger

log = get_logger("dashboard.ws")


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self._connections.add(ws)
        log.info("ws client connected", extra={"total": len(self._connections)})

    def disconnect(self, ws: WebSocket) -> None:
        self._connections.discard(ws)
        log.info("ws client disconnected", extra={"total": len(self._connections)})

    async def broadcast(self, message: dict[str, Any]) -> None:
        if not self._connections:
            return
        data  = json.dumps(message, default=str)
        dead: set[WebSocket] = set()
        await asyncio.gather(
            *[self._send(ws, data, dead) for ws in list(self._connections)],
            return_exceptions=True,
        )
        for ws in dead:
            self._connections.discard(ws)

    async def _send(self, ws: WebSocket, data: str, dead: set) -> None:
        try:
            await ws.send_text(data)
        except Exception:
            dead.add(ws)

    @property
    def count(self) -> int:
        return len(self._connections)
