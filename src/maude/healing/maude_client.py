# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""MaudeClient — memory-as-a-service proxy for standalone rooms.

Provides the same interface as MemoryStore so RoomAgent can use it as a
drop-in replacement. Currently wraps MemoryStore directly; the transport
can be swapped to MCP-over-HTTP in a future phase without changing the
public API.

Usage:
    from maude.healing.maude_client import MaudeClient

    client = MaudeClient(project="redis")
    mem_id = await client.store_memory(project="redis", memory_type="incident", ...)
    recent = await client.recall_recent("redis", limit=5)
    await client.close()

Authors: John Broadway
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-02-13
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class MaudeMemory:
    """Lightweight memory record returned by MaudeClient.

    Matches the fields RoomAgent reads from Memory objects.
    """

    id: int | None = None
    project: str = ""
    memory_type: str = ""
    trigger: str = ""
    reasoning: str = ""
    actions_taken: list[dict[str, Any]] | None = None
    outcome: str = ""
    summary: str = ""
    score: float = 0.0
    created_at: str | None = None


class MaudeClient:
    """Memory-as-a-service client for standalone Maude rooms.

    Presents the same async interface that RoomAgent expects from MemoryStore:
    ``store_memory``, ``recall_recent``, ``recall_similar``, ``embed_and_store``.

    Currently uses MemoryStore directly (local PG + Qdrant connections).
    Future: swap to MCP-over-HTTP transport to Maude Coordinator,
    centralizing all memory connections on a single host.

    Args:
        project: Default project name for this client.
    """

    def __init__(self, project: str) -> None:
        self.project = project
        self._store: Any | None = None

    def _get_store(self) -> Any:
        """Lazy-init the underlying MemoryStore."""
        if self._store is None:
            from maude.memory.store import MemoryStore

            self._store = MemoryStore(project=self.project)
        return self._store

    async def store_memory(
        self,
        project: str,
        memory_type: str,
        summary: str,
        trigger: str = "",
        reasoning: str = "",
        outcome: str = "",
        actions_taken: list[dict[str, Any]] | None = None,
        tokens_used: int = 0,
        model: str = "",
        conversation: list[dict[str, Any]] | None = None,
    ) -> int | None:
        """Store a memory. Returns the PostgreSQL row ID or None."""
        store = self._get_store()
        return await store.store_memory(
            project=project,
            memory_type=memory_type,
            summary=summary,
            trigger=trigger,
            reasoning=reasoning,
            outcome=outcome,
            actions_taken=actions_taken,
            tokens_used=tokens_used,
            model=model,
            conversation=conversation,
        )

    async def recall_recent(
        self,
        project: str,
        memory_type: str | None = None,
        limit: int = 10,
    ) -> list[MaudeMemory]:
        """Recall recent memories from PostgreSQL."""
        store = self._get_store()
        memories = await store.recall_recent(
            project=project,
            memory_type=memory_type,
            limit=limit,
        )
        return [_convert(m) for m in memories]

    async def recall_by_id(self, memory_id: int, project: str) -> MaudeMemory | None:
        """Recall a single memory by its PostgreSQL ID."""
        store = self._get_store()
        m = await store.recall_by_id(memory_id, project)
        if m is None:
            return None
        return _convert(m)

    async def recall_similar(
        self,
        project: str,
        query_text: str,
        limit: int = 5,
    ) -> list[MaudeMemory] | None:
        """Recall semantically similar memories from Qdrant.

        Returns list on success, None if Qdrant is unavailable.
        """
        store = self._get_store()
        memories = await store.recall_similar(
            project=project,
            query_text=query_text,
            limit=limit,
        )
        if memories is None:
            return None
        return [_convert(m) for m in memories]

    async def embed_and_store(
        self,
        memory_id: int,
        summary: str,
        memory_type: str,
        outcome: str,
        *,
        actions_summary: str = "",
        root_cause: str = "",
        tools_used: list[str] | None = None,
    ) -> bool:
        """Embed a memory summary into Qdrant for semantic recall."""
        store = self._get_store()
        return await store.embed_and_store(
            memory_id=memory_id,
            summary=summary,
            memory_type=memory_type,
            outcome=outcome,
            actions_summary=actions_summary,
            root_cause=root_cause,
            tools_used=tools_used,
        )

    async def close(self) -> None:
        """Clean up underlying connections."""
        if self._store is not None:
            await self._store.close()
            self._store = None


def _convert(m: Any) -> MaudeMemory:
    """Convert a MemoryStore Memory object to MaudeMemory."""
    return MaudeMemory(
        id=m.id,
        project=m.project,
        memory_type=m.memory_type,
        trigger=getattr(m, "trigger", ""),
        reasoning=getattr(m, "reasoning", ""),
        actions_taken=getattr(m, "actions_taken", None),
        outcome=m.outcome,
        summary=m.summary,
        score=getattr(m, "score", 0.0),
        created_at=str(m.created_at) if m.created_at else None,
    )
