"""Per-room memory tools — project-bound memory-as-a-service.

Registers 8 memory tools on a FastMCP instance with the project bound at
registration time (no ``project`` parameter in tool signatures). This is the
per-room counterpart to ``coordination/_memory_tools.py`` which uses
project-parameterized tools for cross-room access.

Tool names match ``guest_book.EXCLUDED_TOOLS`` exactly (no ``coordinator_`` prefix).

Usage:
    from maude.memory.memory_tools import register_memory_tools

    register_memory_tools(mcp, audit, "grafana")

Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-02-13
"""

import logging
from pathlib import Path
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db import format_json as _format
from maude.memory.store import MemoryStore

logger = logging.getLogger(__name__)


def _get_store(project: str) -> MemoryStore:
    """Get or create a MemoryStore for a project."""
    return MemoryStore.get_or_create(project)


def register_memory_tools(
    mcp: Any,
    audit: Any,
    project: str,
    *,
    knowledge_dir: Path | None = None,
    privacy_config: dict[str, Any] | None = None,
) -> None:
    """Register per-room memory tools on a FastMCP instance.

    All tools are project-bound: ``project`` is captured via closure at
    registration time and never appears as a tool parameter.

    Args:
        mcp: FastMCP instance.
        audit: AuditLogger (duck-typed).
        project: Room project name (e.g., "grafana", "example-scada").
        knowledge_dir: Optional path to knowledge/ directory for Tier 1
            loading. Defaults to ``/app/{project}/knowledge/`` if not set.
    """
    if knowledge_dir:
        resolved_knowledge_dir = knowledge_dir
    else:
        maude_path = Path(f"/app/{project}/.maude")
        knowledge_path = Path(f"/app/{project}/knowledge")
        resolved_knowledge_dir = maude_path if maude_path.is_dir() else knowledge_path

    @mcp.tool()
    @audit_logged(audit)
    async def memory_store(
        memory_type: str,
        summary: str,
        trigger: str = "",
        reasoning: str = "",
        outcome: str = "",
    ) -> str:
        """Store a structured memory for this room.

        Args:
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
    async def memory_recall_recent(
        memory_type: str = "",
        limit: int = 10,
    ) -> str:
        """Recall recent memories for this room from PostgreSQL.

        Args:
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
    async def memory_recall_similar(
        query: str,
        limit: int = 5,
    ) -> str:
        """Recall semantically similar memories from Qdrant for this room.

        Args:
            query: Natural language description of what to search for.
            limit: Max results. Defaults to 5.

        Returns:
            JSON list of similar memories ranked by score.
        """
        limit = min(limit, 20)
        store = _get_store(project)
        memories = await store.recall_similar(
            project=project,
            query_text=query,
            limit=limit,
        )
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
    async def memory_recall_by_id(memory_id: int) -> str:
        """Recall a single memory by its PostgreSQL ID.

        Args:
            memory_id: The PostgreSQL row ID.

        Returns:
            JSON with the memory record, or error if not found.
        """
        store = _get_store(project)
        m = await store.recall_by_id(memory_id, project)
        if m is None:
            return _format({"project": project, "error": f"Memory {memory_id} not found"})
        return _format(
            {
                "project": project,
                "memory": {
                    "id": m.id,
                    "type": m.memory_type,
                    "summary": m.summary,
                    "outcome": m.outcome,
                    "trigger": getattr(m, "trigger", ""),
                    "reasoning": getattr(m, "reasoning", ""),
                    "created_at": str(m.created_at) if m.created_at else None,
                },
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def memory_embed(
        memory_id: int,
        summary: str,
        memory_type: str = "incident",
        outcome: str = "",
    ) -> str:
        """Embed a stored memory into Qdrant for semantic search.

        Args:
            memory_id: The PostgreSQL row ID from memory_store.
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
    async def memory_save(
        memory_type: str,
        summary: str,
        trigger: str = "",
        reasoning: str = "",
        outcome: str = "",
    ) -> str:
        """One-shot: store to PostgreSQL + embed in Qdrant.

        Convenience tool that combines memory_store + memory_embed.

        Args:
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
    async def memory_brief(
        memory_type: str = "",
        limit: int = 10,
    ) -> str:
        """Full recall across PostgreSQL + Qdrant for this room.

        Loads Tier 2 (recent PostgreSQL) and Tier 3 (similar memories from Qdrant
        based on the most recent summary).

        Args:
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
        similar: list[Any] = []
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

    @mcp.tool()
    @audit_logged(audit)
    async def memory_load_knowledge() -> str:
        """Load Tier 1 knowledge (.md files) for this room.

        Reads all markdown files from the room's knowledge directory and returns
        their concatenated content. This provides the room's baseline knowledge
        (identity, skills, memory) without database queries.

        Returns:
            JSON with file names and concatenated knowledge content.
        """
        if not resolved_knowledge_dir.exists():
            return _format(
                {
                    "project": project,
                    "error": f"Knowledge directory not found: {resolved_knowledge_dir}",
                    "files": [],
                    "content": "",
                }
            )

        files_found: list[str] = []
        parts: list[str] = []

        for md_file in sorted(resolved_knowledge_dir.rglob("*.md")):
            try:
                text = md_file.read_text(encoding="utf-8")
                rel = md_file.relative_to(resolved_knowledge_dir)
                files_found.append(str(rel))
                parts.append(f"## {rel}\n\n{text}")
            except Exception:
                logger.debug("memory_load_knowledge: failed to read %s", md_file)

        return _format(
            {
                "project": project,
                "knowledge_dir": str(resolved_knowledge_dir),
                "file_count": len(files_found),
                "files": files_found,
                "content": "\n\n---\n\n".join(parts) if parts else "",
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def room_query(
        query: str,
        scope: str = "patterns",
        limit: int = 10,
    ) -> str:
        """Query this room's local memory. Answers the door for cross-room queries.

        Privacy-scoped: controls what data is shared with callers.
        - "patterns": Only patterns and decisions (safe for any caller).
        - "incidents": Patterns + incidents (restricted).
        - "all": Everything (executive callers only).

        Args:
            query: Search query (keyword match via FTS5, falls back to PG).
            scope: Privacy scope — "patterns", "incidents", or "all".
            limit: Max results. Defaults to 10.

        Returns:
            JSON with matching memories scoped by privacy settings.
        """
        store = _get_store(project)
        limit = min(limit, 50)

        # Privacy enforcement
        cfg = privacy_config or {}
        if scope == "incidents" and not cfg.get("share_incidents", False):
            scope = "patterns"

        # Determine allowed memory types from centralized policy
        from maude.memory.types import types_for_scope

        allowed_types = types_for_scope(scope) if scope != "all" else set()

        # Try local FTS5 search first
        local_store = getattr(store, "_local", None)
        if local_store:
            try:
                results = await local_store.search_fts(query, limit=limit)
                if allowed_types:
                    results = [r for r in results if r.get("memory_type") in allowed_types]
                if results:
                    from maude.memory.secret_scanner import redact_memories

                    raw_results = [
                        {
                            "id": r.get("pg_id") or -(r.get("id") or 0),
                            "type": r.get("memory_type", ""),
                            "summary": r.get("summary", ""),
                            "outcome": r.get("outcome", ""),
                        }
                        for r in results[:limit]
                    ]
                    return _format(
                        {
                            "project": project,
                            "scope": scope,
                            "source": "local",
                            "count": len(raw_results),
                            "results": redact_memories(raw_results, project),
                        }
                    )
            except Exception:
                logger.debug("room_query: FTS5 search failed, falling back to PG")

        # Fallback: PG recall
        type_filter = None
        if len(allowed_types) == 1:
            type_filter = next(iter(allowed_types))
        memories = await store.recall_recent(
            project=project,
            memory_type=type_filter,
            limit=limit,
        )
        if allowed_types and type_filter is None:
            memories = [m for m in memories if m.memory_type in allowed_types]

        from maude.memory.secret_scanner import redact_memories

        raw_results = [
            {
                "id": m.id,
                "type": m.memory_type,
                "summary": m.summary,
                "outcome": m.outcome,
                "created_at": str(m.created_at) if m.created_at else None,
            }
            for m in memories
        ]
        return _format(
            {
                "project": project,
                "scope": scope,
                "source": "pg",
                "count": len(raw_results),
                "results": redact_memories(raw_results, project),
            }
        )
