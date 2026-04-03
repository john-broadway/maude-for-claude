# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Cross-project Memory MCP Server — Universal three-tier memory API
# Version: 2.0.0
# Created: 2026-03-26 MST
# Author(s): Claude Opus 4.6
#
"""Cross-project Memory MCP Server — Universal three-tier memory API.

Tier 1: Knowledge files (.md) — identity, skills, learned memory
Tier 2: PostgreSQL agent_memory table — structured recall
Tier 3: Qdrant vector collections — semantic similarity search

This runs as a standalone stdio FastMCP server, separate from the main
room daemon. The room daemon provides room-scoped memory (bound
to "my-service"); this server provides cross-project memory access with
an explicit `project` parameter on every tool.

Usage:
    python -m maude.memory.mcp_server
"""

import json
import logging
from pathlib import Path
from typing import Any

from fastmcp import FastMCP

from maude.memory.knowledge import KnowledgeManager
from maude.memory.store import Memory, MemoryStore

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PROJECTS_DIR = Path.home() / "projects"

# Domain groups under ~/projects/
_DOMAIN_GROUPS = ("agency", "industrial", "infrastructure", "apps")

# Canonical project paths — bare name → domain-grouped path.
# Override by setting MAUDE_PROJECT_MAP_PATH to a YAML file with your own mappings.
PROJECT_MAP: dict[str, str] = {
    # Example entries — customize for your deployment:
    # "my-app": "apps/my-app",
    # "my-infra": "infrastructure/my-infra",
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


mcp = FastMCP(
    name="Maude Memory",
    instructions=(
        "Three-tier memory system for Maude agents. "
        "Stores and recalls memories across knowledge files (Tier 1), "
        "PostgreSQL (Tier 2), and Qdrant vectors (Tier 3)."
    ),
)

# Lazy cache of per-project MemoryStore instances
_stores: dict[str, MemoryStore] = {}


def _get_store(project: str) -> MemoryStore:
    """Get or create a MemoryStore for a project."""
    if project not in _stores:
        _stores[project] = MemoryStore(project=project)
    return _stores[project]


def _get_knowledge_manager(project: str) -> KnowledgeManager:
    """Create a KnowledgeManager for a project's knowledge directory."""
    project_path = _resolve_project_path(project)
    knowledge_dir = project_path / "knowledge"
    return KnowledgeManager(knowledge_dir=knowledge_dir, repo_dir=project_path)


def _format(data: Any) -> str:
    """Format response as JSON string."""
    return json.dumps(data, indent=2, default=str)


def _memory_to_dict(m: Memory) -> dict[str, Any]:
    """Convert a Memory dataclass to a serializable dict."""
    return {
        "id": m.id,
        "project": m.project,
        "memory_type": m.memory_type,
        "trigger": m.trigger,
        "context": m.context,
        "reasoning": m.reasoning,
        "actions_taken": m.actions_taken,
        "outcome": m.outcome,
        "summary": m.summary,
        "tokens_used": m.tokens_used,
        "model": m.model,
        "created_at": str(m.created_at) if m.created_at else None,
        "score": m.score,
    }


# =============================================================================
# Tier 1 — Knowledge Files
# =============================================================================


@mcp.tool()
async def memory_load_knowledge(project: str) -> str:
    """Load all knowledge files for a project (identity + skills + memory).

    Returns concatenated system prompt from the project's knowledge/ directory.
    Files are loaded in order: identity.md, skills/*.md, memory/*.md.

    Args:
        project: Project name (e.g., "my-service", "collector")
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
async def memory_update_knowledge(
    project: str,
    category: str,
    entry: str,
) -> str:
    """Append an entry to a project's memory category file.

    Writes to knowledge/memory/{category}.md. Creates the file if it doesn't exist.

    Args:
        project: Project name (e.g., "my-service")
        category: Memory category (e.g., "incidents", "patterns", "preferences")
        entry: Text to append as a new timestamped entry
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


# =============================================================================
# Tier 2 — PostgreSQL
# =============================================================================


@mcp.tool()
async def memory_store(
    project: str,
    memory_type: str,
    summary: str,
    trigger: str = "",
    context: str = "{}",
    reasoning: str = "",
    actions_taken: str = "[]",
    outcome: str = "",
    tokens_used: int = 0,
    model: str = "",
) -> str:
    """Store a structured memory in PostgreSQL.

    Args:
        project: Project name (e.g., "my-service")
        memory_type: Type of memory (e.g., "incident", "pattern", "decision", "preference")
        summary: Brief description of what happened or was learned
        trigger: What triggered this memory (e.g., "alert fired", "user request")
        context: JSON string of contextual data
        reasoning: Why certain actions were taken
        actions_taken: JSON array string of action dicts
        outcome: Result of the actions
        tokens_used: Tokens consumed (if applicable)
        model: Model used (if applicable)
    """
    store = _get_store(project)

    try:
        ctx = json.loads(context) if isinstance(context, str) else context
    except json.JSONDecodeError:
        ctx = {"raw": context}

    try:
        actions = json.loads(actions_taken) if isinstance(actions_taken, str) else actions_taken
    except json.JSONDecodeError:
        actions = []

    row_id = await store.store_memory(
        project=project,
        memory_type=memory_type,
        summary=summary,
        trigger=trigger,
        context=ctx,
        reasoning=reasoning,
        actions_taken=actions,
        outcome=outcome,
        tokens_used=tokens_used,
        model=model,
    )

    return _format(
        {
            "project": project,
            "memory_type": memory_type,
            "id": row_id,
            "success": row_id is not None,
        }
    )


@mcp.tool()
async def memory_recall_recent(
    project: str,
    memory_type: str = "",
    limit: int = 10,
) -> str:
    """Recall recent memories from PostgreSQL.

    Args:
        project: Project name to query
        memory_type: Optional filter (e.g., "incident", "pattern"). Empty returns all types.
        limit: Max number of results (default 10)
    """
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
            "memories": [_memory_to_dict(m) for m in memories],
        }
    )


@mcp.tool()
async def memory_recall_by_id(project: str, memory_id: int) -> str:
    """Fetch a single memory by its PostgreSQL ID.

    Args:
        project: Project name (used for connection routing)
        memory_id: Row ID from agent_memory table
    """
    store = _get_store(project)
    pool = await store._ensure_pool()
    if pool is None:
        return _format({"error": "PostgreSQL unavailable", "id": memory_id})

    try:
        row = await pool.fetchrow(
            """SELECT id, project, memory_type, trigger, context, reasoning,
                      actions_taken, outcome, summary, tokens_used, model, created_at
               FROM agent_memory WHERE id = $1""",
            memory_id,
        )
        if row is None:
            return _format({"error": f"Memory #{memory_id} not found", "id": memory_id})

        from maude.memory.store import _row_to_memory

        memory = _row_to_memory(row)
        return _format({"memory": _memory_to_dict(memory)})
    except Exception as e:
        return _format({"error": str(e), "id": memory_id})


# =============================================================================
# Tier 3 — Qdrant Vectors
# =============================================================================


@mcp.tool()
async def memory_recall_similar(
    project: str,
    query: str,
    limit: int = 5,
) -> str:
    """Semantic search — find memories similar to query text.

    Uses bge-large-en-v1.5 (1024-dim) via vLLM to embed the query, then
    searches the project's Qdrant collection for similar memories.

    Args:
        project: Project name to search
        query: Natural language query to find similar memories
        limit: Max results (default 5)
    """
    store = _get_store(project)
    memories = await store.recall_similar(
        project=project,
        query_text=query,
        limit=limit,
    )
    if memories is None:
        memories = []
    return _format(
        {
            "project": project,
            "query": query,
            "count": len(memories),
            "memories": [_memory_to_dict(m) for m in memories],
        }
    )


@mcp.tool()
async def memory_embed(project: str, memory_id: int) -> str:
    """Embed a stored memory into Qdrant for future semantic recall.

    Reads the memory from PostgreSQL by ID, generates a bge-large-en-v1.5
    embedding via vLLM, and upserts it to the project's Qdrant collection.

    Args:
        project: Project name
        memory_id: PostgreSQL row ID to embed
    """
    store = _get_store(project)

    pool = await store._ensure_pool()
    if pool is None:
        return _format({"error": "PostgreSQL unavailable", "memory_id": memory_id})

    try:
        row = await pool.fetchrow(
            "SELECT summary, memory_type, outcome FROM agent_memory WHERE id = $1",
            memory_id,
        )
        if row is None:
            return _format({"error": f"Memory #{memory_id} not found", "memory_id": memory_id})

        success = await store.embed_and_store(
            memory_id=memory_id,
            summary=row["summary"],
            memory_type=row["memory_type"],
            outcome=row["outcome"] or "",
        )
        return _format(
            {
                "memory_id": memory_id,
                "project": project,
                "embedded": success,
            }
        )
    except Exception as e:
        return _format({"error": str(e), "memory_id": memory_id})


# =============================================================================
# Combined / Convenience
# =============================================================================


@mcp.tool()
async def memory_save(
    project: str,
    memory_type: str,
    summary: str,
    category: str = "",
    trigger: str = "",
    context: str = "{}",
    reasoning: str = "",
    actions_taken: str = "[]",
    outcome: str = "",
    tokens_used: int = 0,
    model: str = "",
) -> str:
    """Full save: store in PostgreSQL + embed in Qdrant + optionally append to knowledge file.

    One-shot convenience tool. Combines memory_store + memory_embed + memory_update_knowledge.

    Args:
        project: Project name
        memory_type: Type of memory (e.g., "incident", "pattern", "decision")
        summary: Brief description
        category: Knowledge file category to append to (e.g., "incidents"). Empty skips Tier 1.
        trigger: What triggered this memory
        context: JSON string of contextual data
        reasoning: Why actions were taken
        actions_taken: JSON array string of action dicts
        outcome: Result of the actions
        tokens_used: Tokens consumed
        model: Model used
    """
    results: dict[str, Any] = {"project": project, "memory_type": memory_type}

    # Tier 2: PostgreSQL
    store = _get_store(project)
    try:
        ctx = json.loads(context) if isinstance(context, str) else context
    except json.JSONDecodeError:
        ctx = {"raw": context}
    try:
        actions = json.loads(actions_taken) if isinstance(actions_taken, str) else actions_taken
    except json.JSONDecodeError:
        actions = []

    row_id = await store.store_memory(
        project=project,
        memory_type=memory_type,
        summary=summary,
        trigger=trigger,
        context=ctx,
        reasoning=reasoning,
        actions_taken=actions,
        outcome=outcome,
        tokens_used=tokens_used,
        model=model,
    )
    results["pg_id"] = row_id
    results["pg_success"] = row_id is not None

    # Tier 3: Qdrant embed
    if row_id is not None:
        embedded = await store.embed_and_store(
            memory_id=row_id,
            summary=summary,
            memory_type=memory_type,
            outcome=outcome,
        )
        results["qdrant_embedded"] = embedded
    else:
        results["qdrant_embedded"] = False

    # Tier 1: Knowledge file (optional)
    if category:
        km = _get_knowledge_manager(project)
        km_success = await km.update_memory(category, summary)
        results["knowledge_updated"] = km_success
        results["knowledge_category"] = category

    return _format(results)


@mcp.tool()
async def memory_brief(
    project: str,
    query: str = "",
    recent_limit: int = 10,
    similar_limit: int = 5,
) -> str:
    """Full recall: load knowledge + recall recent + recall similar.

    One-shot convenience tool for briefing an agent on a project's memory.
    Returns combined context from all three tiers.

    Args:
        project: Project name
        query: Optional query for semantic search (Tier 3). Empty skips vector recall.
        recent_limit: Max recent memories from PostgreSQL
        similar_limit: Max similar memories from Qdrant
    """
    results: dict[str, Any] = {"project": project}

    # Tier 1: Knowledge files
    km = _get_knowledge_manager(project)
    if km.knowledge_dir.is_dir():
        knowledge = await km.load_knowledge()
        results["knowledge"] = knowledge
        results["knowledge_chars"] = len(knowledge)
    else:
        results["knowledge"] = ""
        results["knowledge_chars"] = 0

    # Tier 2: Recent PostgreSQL memories
    store = _get_store(project)
    recent = await store.recall_recent(project=project, limit=recent_limit)
    results["recent_count"] = len(recent)
    results["recent"] = [_memory_to_dict(m) for m in recent]

    # Tier 3: Qdrant similarity (only if query provided)
    if query:
        result = await store.recall_similar(project=project, query_text=query, limit=similar_limit)
        similar = result if result is not None else []
        results["similar_count"] = len(similar)
        results["similar"] = [_memory_to_dict(m) for m in similar]
    else:
        results["similar_count"] = 0
        results["similar"] = []

    return _format(results)


@mcp.tool()
async def memory_list_projects() -> str:
    """List all projects that have knowledge directories or memory collections.

    Scans ~/projects/ domain groups and top-level dirs for knowledge/ directories.
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


def main() -> None:
    """Run the MCP server."""
    logger.info("Starting Maude Memory MCP Server")
    mcp.run()


if __name__ == "__main__":
    main()
