# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Chat session management — in-memory store with optional Redis persistence."""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from maude.infra.redis_client import MaudeRedis

logger = logging.getLogger(__name__)

_REDIS_PREFIX = "concierge:session:"


@dataclass
class ChatSession:
    """In-memory chat session."""

    session_id: str
    messages: list[dict[str, Any]] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    last_active: float = field(default_factory=time.time)


class ChatSessionStore:
    """In-memory session store with optional Redis write-through persistence."""

    def __init__(
        self,
        ttl_minutes: int = 30,
        max_sessions: int = 20,
        max_messages: int = 10,
        redis: MaudeRedis | None = None,
    ) -> None:
        self._sessions: dict[str, ChatSession] = {}
        self._ttl = ttl_minutes * 60
        self._max_sessions = max_sessions
        self._max_messages = max_messages
        self._eviction_task: asyncio.Task[None] | None = None
        self._redis = redis

    def get_or_create(self, session_id: str) -> ChatSession:
        """Get existing session or create a new one.

        Checks in-memory first, then Redis (read-through), then creates new.
        """
        if not session_id:
            session_id = str(uuid.uuid4())

        session = self._sessions.get(session_id)
        if session is None:
            session = ChatSession(session_id=session_id)
            self._sessions[session_id] = session
        session.last_active = time.time()
        return session

    async def get_or_create_async(self, session_id: str) -> ChatSession:
        """Async version with Redis read-through on cache miss."""
        if not session_id:
            session_id = str(uuid.uuid4())

        session = self._sessions.get(session_id)
        if session is None and self._redis:
            session = await self._load_from_redis(session_id)
        if session is None:
            session = ChatSession(session_id=session_id)
        self._sessions[session_id] = session
        session.last_active = time.time()
        return session

    async def persist(self, session: ChatSession) -> None:
        """Write-through: save session messages to Redis."""
        if not self._redis:
            return
        try:
            key = f"{_REDIS_PREFIX}{session.session_id}"
            await self._redis.set(
                key,
                json.dumps(session.messages),
                ttl=self._ttl,
            )
        except Exception:
            logger.debug("Redis write-through failed for session %s", session.session_id)

    async def _load_from_redis(self, session_id: str) -> ChatSession | None:
        """Attempt to restore a session from Redis."""
        if not self._redis:
            return None
        try:
            key = f"{_REDIS_PREFIX}{session_id}"
            data = await self._redis.get(key)
            if data:
                messages = json.loads(data)
                logger.debug("Restored session %s from Redis (%d messages)",
                             session_id, len(messages))
                return ChatSession(session_id=session_id, messages=messages)
        except Exception:
            logger.debug("Redis read-through failed for session %s", session_id)
        return None

    def clear(self, session_id: str) -> None:
        """Clear a session's messages."""
        session = self._sessions.get(session_id)
        if session:
            session.messages.clear()

    def trim_messages(self, session: ChatSession) -> None:
        """Trim oldest messages if over limit."""
        if len(session.messages) > self._max_messages:
            excess = len(session.messages) - self._max_messages
            session.messages = session.messages[excess:]

    def evict_stale(self) -> int:
        """Remove sessions older than TTL. Returns count evicted."""
        now = time.time()
        stale = [
            sid for sid, s in self._sessions.items()
            if now - s.last_active > self._ttl
        ]
        for sid in stale:
            del self._sessions[sid]

        # Also cap total sessions
        if len(self._sessions) > self._max_sessions:
            by_age = sorted(self._sessions.items(), key=lambda x: x[1].last_active)
            to_remove = len(self._sessions) - self._max_sessions
            for sid, _ in by_age[:to_remove]:
                del self._sessions[sid]
                stale.append(sid)

        return len(stale)

    async def start_eviction_loop(self) -> None:
        """Start background eviction task."""
        self._eviction_task = asyncio.create_task(self._eviction_loop())

    async def stop_eviction_loop(self) -> None:
        """Stop background eviction task."""
        if self._eviction_task:
            self._eviction_task.cancel()
            try:
                await self._eviction_task
            except asyncio.CancelledError:
                pass
            self._eviction_task = None

    async def _eviction_loop(self) -> None:
        """Periodically evict stale sessions."""
        while True:
            await asyncio.sleep(60)
            count = self.evict_stale()
            if count:
                logger.info("Chat session eviction: removed %d stale sessions", count)
