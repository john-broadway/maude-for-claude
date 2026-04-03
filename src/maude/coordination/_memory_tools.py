# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Maude memory tools — project-parameterized memory-as-a-service.

Registers multi-tenant memory tools on a FastMCP instance. Unlike per-room
memory tools (which bind to a single project), these accept ``project`` as
a parameter, enabling cross-room memory access from Maude.

Used by both server.py (stdio for Claude Code) and mcp.py (HTTP for rooms).

         Claude (Anthropic) <noreply@anthropic.com>
"""

import logging
from pathlib import Path
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db import format_json as _format
from maude.memory.knowledge import KnowledgeManager
from maude.memory.store import MemoryStore

logger = logging.getLogger(__name__)


def _get_store(project: str) -> MemoryStore:
    """Get or create a MemoryStore for a project."""
    return MemoryStore.get_or_create(project)


PROJECTS_DIR = Path.home() / "projects"

# Domain groups under ~/projects/
_DOMAIN_GROUPS = ("agency", "industrial", "infrastructure", "apps")

# Canonical project paths — bare name → domain-grouped path
PROJECT_MAP: dict[str, str] = {
    # infrastructure/
    "maude": "maude",
    # top-level
    "pixel": "pixel",
    # industrial/
    "example-scada": "industrial/example-scada",
    "lab-service": "industrial/lab-service",
    "alert-display": "industrial/alert-display",
    # infrastructure/
    "proxmox": "infrastructure/proxmox",
    "unifi": "infrastructure/unifi",
    "gpu": "infrastructure/gpu",
    "postgresql": "infrastructure/postgresql",
    "grafana": "infrastructure/grafana",
    "prometheus": "infrastructure/prometheus",
    "loki": "infrastructure/loki",
    "influxdb": "infrastructure/influxdb",
    "qdrant": "infrastructure/qdrant",
    "gitea": "infrastructure/gitea",
    "redis": "infrastructure/redis",
    "uptime-kuma": "infrastructure/uptime-kuma",
    "dns": "infrastructure/dns",
    "unas": "infrastructure/unas",
    "doc-search": "infrastructure/doc-search",
    # apps/
    "erp": "apps/erp",
    # top-level
    "my-service": "my-service",
}


def _resolve_project_path(project: str) -> Path:
    """Resolve a bare project name to its grouped path under ~/projects/."""
    grouped = PROJECT_MAP.get(project)
    if grouped:
        return PROJECTS_DIR / grouped
    # If already a grouped path (e.g., "infrastructure/prometheus"), use directly
    candidate = PROJECTS_DIR / project
    if candidate.exists():
        return candidate
    # Fallback: search domain groups for the project name
    for group in _DOMAIN_GROUPS:
        grouped_path = PROJECTS_DIR / group / project
        if grouped_path.exists():
            return grouped_path
    # Last resort — return bare (will fail gracefully downstream)
    return candidate


def _get_knowledge_manager(project: str) -> KnowledgeManager:
    """Create a KnowledgeManager for a project's knowledge directory."""
    project_path = _resolve_project_path(project)
    knowledge_dir = project_path / "knowledge"
    return KnowledgeManager(knowledge_dir=knowledge_dir, repo_dir=project_path)


def register_memory_tools(mcp: Any, audit: Any) -> None:
    """Register Maude memory-as-a-service tools on a FastMCP instance.

    These tools are project-parameterized: any room can store/recall memories
    through Maude instead of managing its own PG + Qdrant connections.

    Args:
        mcp: FastMCP instance.
        audit: AuditLogger or NullAudit (duck-typed).
    """

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_store(
        project: str,
        memory_type: str,
        summary: str,
        trigger: str = "",
        reasoning: str = "",
        outcome: str = "",
    ) -> str:
        """Store a structured memory for any room via Maude.

        Args:
            project: Room project name (e.g., "my-service", "database").
            memory_type: Type of memory (e.g., "incident", "pattern", "decision").
            summary: Brief description of what happened.
            trigger: What triggered this memory.
            reasoning: Analysis or reasoning.
            outcome: Result (e.g., "resolved", "escalated", "failed").

        Returns:
            JSON with the PostgreSQL row ID.
        """
        store = _get_store(project)
        mem_id = await store.store_memory(
            project=project,
            memory_type=memory_type,
            summary=summary,
            trigger=trigger,
            reasoning=reasoning,
            outcome=outcome,
        )
        return _format({"project": project, "memory_id": mem_id, "stored": mem_id is not None})

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_recall_recent(
        project: str,
        memory_type: str = "",
        limit: int = 10,
    ) -> str:
        """Recall recent memories for any room via Maude.

        Args:
            project: Room project name.
            memory_type: Optional filter (e.g., "incident"). Empty = all types.
            limit: Max results. Defaults to 10.

        Returns:
            JSON list of recent memories.
        """
        limit = min(limit, 50)
        store = _get_store(project)
        memories = await store.recall_recent(
            project=project,
            memory_type=memory_type if memory_type else None,
            limit=limit,
        )
        return _format(
            {
                "project": project,
                "count": len(memories),
                "memories": [
                    {
                        "id": m.id,
                        "type": m.memory_type,
                        "summary": m.summary,
                        "outcome": m.outcome,
                        "trigger": m.trigger,
                        "created_at": str(m.created_at) if m.created_at else None,
                    }
                    for m in memories
                ],
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_recall_similar(
        project: str,
        query: str,
        limit: int = 5,
    ) -> str:
        """Recall semantically similar memories for any room via Maude.

        Args:
            project: Room project name.
            query: Natural language description of what to search for.
            limit: Max results. Defaults to 5.

        Returns:
            JSON list of similar memories ranked by score.
        """
        limit = min(limit, 20)
        store = _get_store(project)
        memories = await store.recall_similar(project=project, query_text=query, limit=limit)
        if memories is None:
            return _format(
                {
                    "project": project,
                    "error": "Qdrant unavailable — semantic recall skipped",
                    "count": 0,
                    "memories": [],
                }
            )
        return _format(
            {
                "project": project,
                "count": len(memories),
                "memories": [
                    {
                        "id": m.id,
                        "type": m.memory_type,
                        "summary": m.summary,
                        "outcome": m.outcome,
                        "score": round(m.score, 3),
                        "created_at": str(m.created_at) if m.created_at else None,
                    }
                    for m in memories
                ],
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_embed(
        project: str,
        memory_id: int,
        summary: str,
        memory_type: str = "incident",
        outcome: str = "",
    ) -> str:
        """Embed a stored memory into Qdrant for semantic search via Maude.

        Args:
            project: Room project name.
            memory_id: The PostgreSQL row ID from maude_memory_store.
            summary: The text to embed.
            memory_type: Memory type for payload metadata.
            outcome: Outcome for payload metadata.

        Returns:
            JSON with embedding success status.
        """
        store = _get_store(project)
        ok = await store.embed_and_store(
            memory_id=memory_id,
            summary=summary,
            memory_type=memory_type,
            outcome=outcome,
        )
        return _format({"project": project, "memory_id": memory_id, "embedded": ok})

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_save(
        project: str,
        memory_type: str,
        summary: str,
        trigger: str = "",
        reasoning: str = "",
        outcome: str = "",
    ) -> str:
        """One-shot: store to PostgreSQL + embed in Qdrant via Maude.

        Convenience tool that combines maude_memory_store + maude_memory_embed.

        Args:
            project: Room project name.
            memory_type: Type of memory (e.g., "incident", "pattern", "decision").
            summary: Brief description.
            trigger: What triggered this.
            reasoning: Analysis or reasoning.
            outcome: Result (e.g., "resolved", "escalated").

        Returns:
            JSON with PostgreSQL ID and Qdrant embedding status.
        """
        store = _get_store(project)
        result: dict[str, Any] = {"project": project}

        # Tier 2: PostgreSQL
        mem_id = await store.store_memory(
            project=project,
            memory_type=memory_type,
            summary=summary,
            trigger=trigger,
            reasoning=reasoning,
            outcome=outcome,
        )
        result["memory_id"] = mem_id
        result["pg_stored"] = mem_id is not None

        # Tier 3: Qdrant
        if mem_id:
            embedded = await store.embed_and_store(
                memory_id=mem_id,
                summary=summary,
                memory_type=memory_type,
                outcome=outcome,
            )
            result["qdrant_embedded"] = embedded

        return _format(result)

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_brief(
        project: str,
        memory_type: str = "",
        limit: int = 10,
    ) -> str:
        """Full recall across PostgreSQL + Qdrant for any room via Maude.

        Loads Tier 2 (recent PostgreSQL) and Tier 3 (similar memories from Qdrant
        based on the most recent summary).

        Args:
            project: Room project name.
            memory_type: Optional filter for Tier 2 recall.
            limit: Max results per tier. Defaults to 10.

        Returns:
            JSON with recent and similar memories.
        """
        limit = min(limit, 50)
        store = _get_store(project)

        # Tier 2: Recent memories
        recent = await store.recall_recent(
            project=project,
            memory_type=memory_type if memory_type else None,
            limit=limit,
        )

        # Tier 3: Similar to most recent summary
        similar: list = []
        if recent:
            query = recent[0].summary
            result = await store.recall_similar(
                project=project,
                query_text=query,
                limit=limit,
            )
            if result is not None:
                similar = result

        return _format(
            {
                "project": project,
                "tier2_recent_count": len(recent),
                "tier2_recent": [
                    {
                        "id": m.id,
                        "type": m.memory_type,
                        "summary": m.summary,
                        "outcome": m.outcome,
                        "created_at": str(m.created_at) if m.created_at else None,
                    }
                    for m in recent
                ],
                "tier3_similar_count": len(similar),
                "tier3_similar": [
                    {
                        "id": m.id,
                        "type": m.memory_type,
                        "summary": m.summary,
                        "outcome": m.outcome,
                        "score": round(m.score, 3),
                        "created_at": str(m.created_at) if m.created_at else None,
                    }
                    for m in similar
                ],
            }
        )

    # ── Tier 2: Single-record recall ─────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_recall_by_id(
        project: str,
        memory_id: int,
    ) -> str:
        """Fetch a single memory by its PostgreSQL row ID.

        Args:
            project: Room project name (used for connection routing).
            memory_id: Row ID from agent_memory table.

        Returns:
            JSON with full memory record or error.
        """
        store = _get_store(project)
        memory = await store.recall_by_id(memory_id=memory_id, project=project)
        if memory is None:
            return _format({"error": f"Memory #{memory_id} not found", "id": memory_id})
        return _format(
            {
                "memory": {
                    "id": memory.id,
                    "project": memory.project,
                    "type": memory.memory_type,
                    "summary": memory.summary,
                    "trigger": memory.trigger,
                    "reasoning": memory.reasoning,
                    "outcome": memory.outcome,
                    "tokens_used": memory.tokens_used,
                    "model": memory.model,
                    "created_at": str(memory.created_at) if memory.created_at else None,
                },
            }
        )

    # ── Tier 1: Knowledge file tools ─────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_load_knowledge(project: str) -> str:
        """Load all knowledge files for a project (identity + skills + memory).

        Returns concatenated system prompt from the project's knowledge/ directory.
        Files are loaded in order: identity.md, skills/*.md, memory/*.md.

        Args:
            project: Project name (e.g., "my-service", "database").

        Returns:
            JSON with knowledge content and character count.
        """
        km = _get_knowledge_manager(project)
        if not km.knowledge_dir.is_dir():
            return _format(
                {
                    "error": f"No knowledge directory for project '{project}'",
                    "project": project,
                }
            )

        content = await km.load_knowledge()
        if not content:
            return _format(
                {
                    "project": project,
                    "content": "",
                    "note": "Knowledge directory exists but is empty",
                }
            )

        return _format({"project": project, "content": content, "chars": len(content)})

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_update_knowledge(
        project: str,
        category: str,
        entry: str,
    ) -> str:
        """Append an entry to a project's memory category file.

        Writes to knowledge/memory/{category}.md. Creates the file if needed.

        Args:
            project: Project name (e.g., "my-service").
            category: Memory category (e.g., "incidents", "patterns", "preferences").
            entry: Text to append as a new timestamped entry.

        Returns:
            JSON with success status and file path.
        """
        km = _get_knowledge_manager(project)
        success = await km.update_memory(category, entry)
        return _format(
            {
                "project": project,
                "category": category,
                "success": success,
                "file": str(km.knowledge_dir / "memory" / f"{category}.md"),
            }
        )

    # ── Project discovery ────────────────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def maude_memory_list_projects() -> str:
        """List all projects that have knowledge directories.

        Scans ~/projects/ domain groups and top-level dirs for knowledge/ directories.

        Returns:
            JSON list of projects with knowledge directories.
        """
        projects_with_knowledge: list[str] = []

        # Check domain groups (two levels deep)
        for group in _DOMAIN_GROUPS:
            group_dir = PROJECTS_DIR / group
            if group_dir.is_dir():
                for p in sorted(group_dir.iterdir()):
                    if p.is_dir() and (p / "knowledge").is_dir():
                        projects_with_knowledge.append(f"{group}/{p.name}")

        # Check top-level projects
        for p in sorted(PROJECTS_DIR.iterdir()):
            if p.is_dir() and p.name not in _DOMAIN_GROUPS and (p / "knowledge").is_dir():
                projects_with_knowledge.append(p.name)

        return _format(
            {
                "projects_with_knowledge": projects_with_knowledge,
                "projects_dir": str(PROJECTS_DIR),
            }
        )
