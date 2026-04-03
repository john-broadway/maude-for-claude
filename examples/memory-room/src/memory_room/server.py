# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)
"""Memory Room — Maude Room example demonstrating 3-tier memory.

This Room runs with ZERO external infrastructure. PostgreSQL and Qdrant are
optional; the MemoryStore gracefully degrades to its local SQLite tier (Tier 1.5)
when upstream tiers are unavailable.

Memory tier hierarchy:
    Tier 1   — Knowledge files (.maude/knowledge/*.md) — static identity docs
    Tier 1.5 — SQLite at /var/lib/maude/memory-room/memory.db — local sovereign
    Tier 2   — PostgreSQL — shared structured memory (optional)
    Tier 3   — Qdrant — semantic vector search (optional)

The two custom tools ``remember`` and ``recall`` demonstrate the pattern most
Rooms use for structured, typed memories (incidents, patterns, decisions).

Usage:
    python -m memory_room --config config.yaml
"""

import json

from maude.memory.memory_tools import register_memory_tools
from maude.memory.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import run_room
from fastmcp import FastMCP


def create_server(config: RoomConfig) -> FastMCP:
    """Create the Memory Room MCP server."""
    mcp = FastMCP(name="Memory Room")
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    # Standard 11 ops tools: service_status, service_health, service_logs,
    # service_errors, service_restart, kill_switch_activate, kill_switch_deactivate,
    # kill_switch_status, service_log_cleanup, service_log_patterns, service_trends.
    register_ops_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        config.service_name,
        config.project,
        ctid=config.raw.get("room_id", 101),
        ip=config.ip,
    )

    # Standard 8 memory tools: memory_store, memory_recall_recent, memory_recall_similar,
    # memory_recall_by_id, memory_embed, memory_save, memory_brief, memory_load_knowledge,
    # room_query.  All project-bound by closure — no project parameter in signatures.
    register_memory_tools(mcp, audit, config.project)

    # --- Custom tools ---

    @mcp.tool()
    async def remember(
        what: str,
        memory_type: str = "observation",
        outcome: str = "",
        trigger: str = "",
    ) -> str:
        """Store a named memory in this Room.

        A thin convenience wrapper over the underlying ``memory_save`` tool.
        Rooms typically add these to give callers a domain-friendly vocabulary
        (e.g., ``log_incident``, ``record_decision``) rather than exposing the
        generic ``memory_save`` directly.

        Args:
            what: A short description of what to remember.
            memory_type: Semantic category — e.g., "observation", "incident",
                "decision", "pattern". Defaults to "observation".
            outcome: Optional outcome tag (e.g., "resolved", "escalated").
            trigger: What caused this memory to be created.

        Returns:
            JSON with memory_id and storage status.
        """
        from maude.memory.store import MemoryStore

        store = MemoryStore.get_or_create(config.project)
        mem_id = await store.store_memory(
            project=config.project,
            memory_type=memory_type,
            summary=what,
            trigger=trigger,
            outcome=outcome,
        )
        return json.dumps(
            {
                "project": config.project,
                "memory_id": mem_id,
                "stored": mem_id is not None,
                "summary": what,
                "type": memory_type,
            }
        )

    @mcp.tool()
    async def recall(
        memory_type: str = "",
        limit: int = 5,
    ) -> str:
        """Recall recent memories from this Room.

        A focused wrapper over ``memory_recall_recent`` that limits results to
        the most recent 5 by default, suitable for quick context refreshes.

        Args:
            memory_type: Filter by type (e.g., "incident"). Empty = all types.
            limit: Maximum number of memories to return. Capped at 20.

        Returns:
            JSON list of recent memories, newest first.
        """
        from maude.memory.store import MemoryStore

        limit = min(limit, 20)
        store = MemoryStore.get_or_create(config.project)
        memories = await store.recall_recent(
            project=config.project,
            memory_type=memory_type if memory_type else None,
            limit=limit,
        )
        return json.dumps(
            {
                "project": config.project,
                "count": len(memories),
                "memories": [
                    {
                        "id": m.id,
                        "type": m.memory_type,
                        "summary": m.summary,
                        "outcome": m.outcome,
                        "created_at": str(m.created_at) if m.created_at else None,
                    }
                    for m in memories
                ],
            }
        )

    return mcp


def main() -> None:
    """Entry point."""
    run_room(create_server)
