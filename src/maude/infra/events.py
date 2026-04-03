# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Event publisher for cross-room coordination.

Supports two backends:
- **pg** (default): PostgreSQL NOTIFY on ``maude_events`` channel.
- **redis**: Redis Streams for persistent, replayable events.

Fire-and-forget: never blocks the caller, never crashes on failure.

Usage::

    publisher = EventPublisher(project="my-service")
    await publisher.connect()
    await publisher.publish("health_status_changed", {"status": "unhealthy"})
    await publisher.close()
"""

import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import Any

import asyncpg

from maude.daemon.common import load_credentials, resolve_db_host

logger = logging.getLogger(__name__)

CHANNEL = "maude_events"
MAX_PAYLOAD = 7500  # PG NOTIFY limit is 8000 bytes; leave headroom
STREAM_NAME = "maude:events"
STREAM_MAXLEN = 1000


class EventPublisher:
    """Publish structured events via PostgreSQL NOTIFY.

    Args:
        project: Room/project name (e.g., "my-service").
        db_host: PostgreSQL host override. Defaults to credentials file.
        database: Database name. Defaults to "agent".
    """

    def __init__(
        self,
        project: str,
        db_host: str = "",
        database: str = "agent",
    ) -> None:
        self.project = project
        self.database = database
        self._db_host = db_host
        self._conn: asyncpg.Connection | None = None

    async def connect(self) -> None:
        """Establish a dedicated connection for NOTIFY.

        Uses a single connection (not pool) because NOTIFY doesn't need
        concurrency and connection pools may not preserve session state.
        """
        if self._conn is not None:
            return
        try:
            db_host = self._db_host or resolve_db_host()
            creds = load_credentials("database")["postgres"]
            self._conn = await asyncio.wait_for(
                asyncpg.connect(
                    host=db_host,
                    port=creds["port"],
                    database=self.database,
                    user=creds["user"],
                    password=creds["password"],
                ),
                timeout=10.0,
            )
            logger.info("EventPublisher[%s]: connected to %s", self.project, db_host)
        except Exception:
            logger.warning("EventPublisher[%s]: connection failed (non-fatal)", self.project)
            self._conn = None

    async def publish(
        self,
        event_type: str,
        data: dict[str, Any] | None = None,
        room: str = "",
    ) -> bool:
        """Publish an event to the maude_events channel.

        Args:
            event_type: Event identifier (e.g., "health_status_changed").
            data: Event payload dict.
            room: Source room override. Defaults to self.project.

        Returns:
            True if published successfully, False otherwise.
        """
        payload = {
            "room": room or self.project,
            "event": event_type,
            "data": data or {},
            "ts": datetime.now(timezone.utc).isoformat(),
        }

        payload_str = json.dumps(payload, default=str)
        if len(payload_str) > MAX_PAYLOAD:
            # Truncate data to fit
            payload["data"] = {"truncated": True, "event": event_type}
            payload_str = json.dumps(payload, default=str)

        try:
            if self._conn is None:
                await self.connect()
            if self._conn is None:
                return False

            await self._conn.execute("SELECT pg_notify($1, $2)", CHANNEL, payload_str)
            logger.debug("EventPublisher[%s]: %s", self.project, event_type)
            return True
        except Exception:
            logger.warning(
                "EventPublisher[%s]: NOTIFY failed for %s (non-fatal)",
                self.project,
                event_type,
            )
            # Reset connection on failure — will reconnect on next publish
            old_conn = self._conn
            self._conn = None
            if old_conn is not None:
                try:
                    await old_conn.close()
                except Exception:
                    pass
            return False

    async def close(self) -> None:
        """Close the dedicated connection."""
        if self._conn is not None:
            try:
                await self._conn.close()
            except Exception:
                pass
            self._conn = None


class RedisEventPublisher:
    """Publish structured events via Redis Streams with PG NOTIFY fallback.

    Uses ``XADD`` to a shared ``maude:events`` stream with ``MAXLEN ~1000``
    auto-trimming. If Redis is unavailable, falls back to PG NOTIFY.

    Args:
        project: Room/project name.
        redis_client: MaudeRedis instance (or None to disable Redis).
        pg_fallback: Optional EventPublisher for PG NOTIFY fallback.
    """

    def __init__(
        self,
        project: str,
        redis_client: Any = None,
        pg_fallback: EventPublisher | None = None,
    ) -> None:
        self.project = project
        self._redis = redis_client
        self._pg_fallback = pg_fallback

    async def connect(self) -> None:
        """Connect both Redis and PG fallback (if configured)."""
        if self._redis:
            await self._redis.connect()
        if self._pg_fallback:
            await self._pg_fallback.connect()

    async def publish(
        self,
        event_type: str,
        data: dict[str, Any] | None = None,
        room: str = "",
    ) -> bool:
        """Publish event to Redis Streams, falling back to PG NOTIFY."""
        payload = {
            "room": room or self.project,
            "event": event_type,
            "data": json.dumps(data or {}, default=str),
            "ts": datetime.now(timezone.utc).isoformat(),
        }

        # Try Redis first
        if self._redis and self._redis.available:
            try:
                # Use unprefixed stream name for cross-room visibility
                result = await self._redis._redis.xadd(
                    STREAM_NAME,
                    payload,
                    maxlen=STREAM_MAXLEN,
                    approximate=True,
                )
                if result:
                    logger.debug(
                        "RedisEventPublisher[%s]: %s → %s", self.project, event_type, result
                    )
                    return True
            except Exception:
                logger.debug("RedisEventPublisher[%s]: XADD failed, PG fallback", self.project)

        # Fall back to PG NOTIFY
        if self._pg_fallback:
            return await self._pg_fallback.publish(event_type, data, room)

        return False

    async def close(self) -> None:
        """Close connections."""
        if self._pg_fallback:
            await self._pg_fallback.close()
