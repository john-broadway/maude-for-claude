# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Optional Redis client for Maude services.

Thin async wrapper around ``redis.asyncio``. Lazy-connects on first use,
gracefully degrades if Redis is unavailable (all methods return None/False).

All keys are auto-prefixed with ``maude:{project}:`` to avoid collisions
between Rooms sharing the same Redis instance.

Usage::

    client = MaudeRedis(host="localhost", prefix="my-service")
    await client.connect()
    await client.set("last_run", "2026-02-08T12:00:00")
    val = await client.get("last_run")
    await client.close()
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

logger = logging.getLogger(__name__)


class MaudeRedis:
    """Async Redis client with automatic key namespacing.

    Args:
        host: Redis server hostname.
        port: Redis server port.
        db: Redis database index.
        password: Redis password (empty for no auth).
        prefix: Key namespace prefix (typically the project name).
    """

    def __init__(
        self,
        host: str,
        port: int = 6379,
        db: int = 0,
        password: str = "",
        prefix: str = "",
    ) -> None:
        self._host = host
        self._port = port
        self._db = db
        self._password = password
        self._prefix = f"maude:{prefix}:" if prefix else "maude:"
        self._redis: Any = None  # redis.asyncio.Redis instance

    def _key(self, key: str) -> str:
        """Prefix a key with the project namespace."""
        return f"{self._prefix}{key}"

    async def connect(self) -> bool:
        """Connect to Redis. Returns True on success."""
        if self._redis is not None:
            return True
        try:
            from redis.asyncio import Redis

            kwargs: dict[str, Any] = {
                "host": self._host,
                "port": self._port,
                "db": self._db,
                "decode_responses": True,
                "socket_connect_timeout": 5,
                "socket_timeout": 5,
            }
            if self._password:
                kwargs["password"] = self._password

            self._redis = Redis(**kwargs)
            await self._redis.ping()
            logger.info(
                "MaudeRedis: connected to %s:%d (prefix=%s)", self._host, self._port, self._prefix
            )
            return True
        except Exception:
            logger.warning("MaudeRedis: connection to %s:%d failed", self._host, self._port)
            self._redis = None
            return False

    async def close(self) -> None:
        """Close the Redis connection."""
        if self._redis is not None:
            try:
                await self._redis.aclose()
            except Exception:
                pass
            self._redis = None

    @property
    def available(self) -> bool:
        """True if a Redis connection is established."""
        return self._redis is not None

    # ── Cache operations ──────────────────────────────────────────

    async def get(self, key: str) -> str | None:
        """Get a value by key. Returns None on miss or error."""
        if not self._redis:
            return None
        try:
            return await self._redis.get(self._key(key))
        except Exception:
            logger.debug("MaudeRedis: GET %s failed", key)
            return None

    async def set(self, key: str, value: str, ttl: int | None = None) -> bool:
        """Set a key-value pair with optional TTL (seconds)."""
        if not self._redis:
            return False
        try:
            if ttl:
                await self._redis.set(self._key(key), value, ex=ttl)
            else:
                await self._redis.set(self._key(key), value)
            return True
        except Exception:
            logger.debug("MaudeRedis: SET %s failed", key)
            return False

    async def delete(self, key: str) -> bool:
        """Delete a key. Returns True if deleted."""
        if not self._redis:
            return False
        try:
            await self._redis.delete(self._key(key))
            return True
        except Exception:
            logger.debug("MaudeRedis: DEL %s failed", key)
            return False

    # ── Rate limiting ─────────────────────────────────────────────

    async def rate_check(self, key: str, limit: int, window: int) -> dict[str, Any]:
        """Sliding-window rate check using SET NX EX.

        Args:
            key: Rate limit identifier (e.g., "rate:service_restart").
            limit: Max allowed calls in the window (currently enforces limit=1).
            window: Time window in seconds.

        Returns:
            Dict with "allowed" (bool) and "remaining" (seconds until next allowed).
        """
        if not self._redis:
            return {"allowed": True, "remaining": 0}
        try:
            full_key = self._key(key)
            # SET NX EX: only sets if key doesn't exist, with expiry
            was_set = await self._redis.set(full_key, str(time.time()), nx=True, ex=window)
            if was_set:
                return {"allowed": True, "remaining": 0}
            # Key exists — check TTL
            ttl = await self._redis.ttl(full_key)
            return {"allowed": False, "remaining": max(0, ttl)}
        except Exception:
            logger.debug("MaudeRedis: rate_check %s failed, allowing", key)
            return {"allowed": True, "remaining": 0}

    # ── Event streams (Redis Streams) ─────────────────────────────

    async def publish_event(self, stream: str, data: dict[str, Any]) -> str | None:
        """Publish an event to a Redis Stream via XADD.

        Args:
            stream: Stream name (will be prefixed).
            data: Event payload fields (all values converted to strings).

        Returns:
            Stream entry ID on success, None on failure.
        """
        if not self._redis:
            return None
        try:
            fields = {k: json.dumps(v) if not isinstance(v, str) else v for k, v in data.items()}
            entry_id = await self._redis.xadd(
                self._key(stream),
                fields,
                maxlen=1000,
                approximate=True,
            )
            return entry_id
        except Exception:
            logger.debug("MaudeRedis: XADD %s failed", stream)
            return None

    async def read_events(
        self,
        stream: str,
        last_id: str = "$",
        count: int = 10,
        block: int = 0,
    ) -> list[dict[str, Any]]:
        """Read events from a Redis Stream via XREAD.

        Args:
            stream: Stream name (will be prefixed).
            last_id: Read entries after this ID ("$" = only new, "0" = from start).
            count: Max entries to read.
            block: Block timeout in milliseconds (0 = non-blocking).

        Returns:
            List of dicts with "id" and payload fields.
        """
        if not self._redis:
            return []
        try:
            result = await self._redis.xread(
                {self._key(stream): last_id},
                count=count,
                block=block if block > 0 else None,
            )
            events = []
            for _stream_name, entries in result:
                for entry_id, fields in entries:
                    event = {"id": entry_id}
                    for k, v in fields.items():
                        try:
                            event[k] = json.loads(v)
                        except (json.JSONDecodeError, TypeError):
                            event[k] = v
                    events.append(event)
            return events
        except Exception:
            logger.debug("MaudeRedis: XREAD %s failed", stream)
            return []

    # ── Pub/Sub (fire-and-forget broadcast) ───────────────────────

    async def broadcast(self, channel: str, message: str) -> int:
        """Publish a message to a pub/sub channel.

        Args:
            channel: Channel name (will be prefixed).
            message: Message string.

        Returns:
            Number of subscribers that received the message, or 0 on failure.
        """
        if not self._redis:
            return 0
        try:
            return await self._redis.publish(self._key(channel), message)
        except Exception:
            logger.debug("MaudeRedis: PUBLISH %s failed", channel)
            return 0
