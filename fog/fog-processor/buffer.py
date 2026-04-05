"""
Disk-backed message buffer for offline fog operation.

When the AWS IoT Core connection is unavailable, outgoing messages are
persisted to a SQLite database.  When the connection is restored, the
buffer is drained in FIFO order.

Schema
------
CREATE TABLE messages (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    topic     TEXT NOT NULL,
    payload   TEXT NOT NULL,
    queued_at REAL NOT NULL,   -- Unix timestamp
    attempts  INTEGER DEFAULT 0
);
"""
from __future__ import annotations

import asyncio
import time
from typing import AsyncIterator, NamedTuple

import aiosqlite

from shared.utils import get_logger, set_gauge

log = get_logger("fog.buffer")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    topic     TEXT    NOT NULL,
    payload   TEXT    NOT NULL,
    queued_at REAL    NOT NULL,
    attempts  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_queued ON messages(queued_at);
"""


class BufferedMessage(NamedTuple):
    id: int
    topic: str
    payload: str
    queued_at: float
    attempts: int


class MessageBuffer:
    """Async SQLite-backed FIFO queue for MQTT messages."""

    def __init__(self, db_path: str, max_size: int = 10_000) -> None:
        self._db_path = db_path
        self._max_size = max_size
        self._db: aiosqlite.Connection | None = None
        self._lock = asyncio.Lock()

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    async def open(self) -> None:
        self._db = await aiosqlite.connect(self._db_path)
        self._db.row_factory = aiosqlite.Row
        await self._db.executescript(_SCHEMA)
        await self._db.commit()
        size = await self.size()
        log.info("buffer opened", extra={"db": self._db_path, "buffered": size})

    async def close(self) -> None:
        if self._db:
            await self._db.close()
            self._db = None

    # ── Write ─────────────────────────────────────────────────────────────────

    async def enqueue(self, topic: str, payload: str) -> bool:
        """
        Add a message to the buffer.
        Returns False (and drops the message) if the buffer is full.
        """
        async with self._lock:
            if not self._db:
                return False
            current = await self._count()
            if current >= self._max_size:
                log.warning(
                    "buffer full, dropping message",
                    extra={"topic": topic, "size": current},
                )
                return False
            await self._db.execute(
                "INSERT INTO messages (topic, payload, queued_at) VALUES (?, ?, ?)",
                (topic, payload, time.time()),
            )
            await self._db.commit()
            set_gauge("fog.buffer_size", current + 1)
            return True

    # ── Read / drain ──────────────────────────────────────────────────────────

    async def peek_batch(self, limit: int = 50) -> list[BufferedMessage]:
        """Return up to *limit* oldest messages without deleting them."""
        async with self._lock:
            if not self._db:
                return []
            cursor = await self._db.execute(
                "SELECT id, topic, payload, queued_at, attempts "
                "FROM messages ORDER BY id ASC LIMIT ?",
                (limit,),
            )
            rows = await cursor.fetchall()
            return [
                BufferedMessage(
                    id=r["id"], topic=r["topic"], payload=r["payload"],
                    queued_at=r["queued_at"], attempts=r["attempts"],
                )
                for r in rows
            ]

    async def ack(self, message_id: int) -> None:
        """Delete a successfully forwarded message."""
        async with self._lock:
            if self._db:
                await self._db.execute(
                    "DELETE FROM messages WHERE id = ?", (message_id,)
                )
                await self._db.commit()

    async def increment_attempts(self, message_id: int) -> None:
        async with self._lock:
            if self._db:
                await self._db.execute(
                    "UPDATE messages SET attempts = attempts + 1 WHERE id = ?",
                    (message_id,),
                )
                await self._db.commit()

    async def purge_old(self, older_than_seconds: float = 86400 * 7) -> int:
        """Delete messages older than N seconds.  Returns count deleted."""
        cutoff = time.time() - older_than_seconds
        async with self._lock:
            if not self._db:
                return 0
            cursor = await self._db.execute(
                "DELETE FROM messages WHERE queued_at < ?", (cutoff,)
            )
            await self._db.commit()
            n = cursor.rowcount
            if n:
                log.info("purged old buffered messages", extra={"count": n})
            return n

    # ── Stats ─────────────────────────────────────────────────────────────────

    async def size(self) -> int:
        async with self._lock:
            return await self._count()

    async def _count(self) -> int:
        if not self._db:
            return 0
        cursor = await self._db.execute("SELECT COUNT(*) FROM messages")
        row = await cursor.fetchone()
        return row[0] if row else 0
