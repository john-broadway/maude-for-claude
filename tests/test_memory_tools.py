# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for per-room memory tools — project-bound memory-as-a-service."""

import json
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from maude.memory.memory_tools import register_memory_tools

# ── Fixtures ──────────────────────────────────────────────────────


class FakeMCP:
    """Minimal FastMCP stub that captures registered tools."""

    def __init__(self) -> None:
        self.tools_registered: dict[str, object] = {}

    def tool(self):
        def decorator(fn):
            self.tools_registered[fn.__name__] = fn
            return fn

        return decorator


class NullAudit:
    """Audit stub for testing."""

    project: str = "test"


def _make_mcp_with_tools(
    project: str = "monitoring",
    knowledge_dir: Path | None = None,
) -> tuple[FakeMCP, AsyncMock]:
    """Register memory tools and return the FakeMCP + mocked MemoryStore."""
    mcp = FakeMCP()
    audit = NullAudit()
    mock_store = AsyncMock()
    mock_store.store_memory = AsyncMock(return_value=42)
    mock_store.recall_recent = AsyncMock(return_value=[])
    mock_store.recall_similar = AsyncMock(return_value=[])
    mock_store.recall_by_id = AsyncMock(return_value=None)
    mock_store.embed_and_store = AsyncMock(return_value=True)

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        register_memory_tools(mcp, audit, project, knowledge_dir=knowledge_dir)

    return mcp, mock_store


# ── Registration ──────────────────────────────────────────────────


def test_registers_9_tools():
    """All 9 memory tools are registered (8 original + room_query)."""
    mcp, _ = _make_mcp_with_tools()
    expected = {
        "memory_store",
        "memory_recall_recent",
        "memory_recall_similar",
        "memory_recall_by_id",
        "memory_embed",
        "memory_save",
        "memory_brief",
        "memory_load_knowledge",
        "room_query",
    }
    assert set(mcp.tools_registered.keys()) == expected


def test_tool_names_match_guest_book_excluded():
    """Tool names match the EXCLUDED_TOOLS in guest_book.py (minus update_knowledge)."""
    from maude.middleware.guest_book import EXCLUDED_TOOLS

    mcp, _ = _make_mcp_with_tools()
    registered = set(mcp.tools_registered.keys())

    # All memory_* registered tools (except memory_update_knowledge which we
    # don't implement) should be in EXCLUDED_TOOLS. room_query is separate.
    memory_registered = {t for t in registered if t.startswith("memory_")}
    memory_tools_in_excluded = {t for t in EXCLUDED_TOOLS if t.startswith("memory_")}
    assert memory_registered <= memory_tools_in_excluded


# ── No project parameter in tool signatures ──────────────────────


def test_no_project_param_in_tool_signatures():
    """Per-room tools do NOT have a 'project' parameter — it's bound via closure."""
    mcp, _ = _make_mcp_with_tools()
    import inspect

    for name, fn in mcp.tools_registered.items():
        # Unwrap decorators to get the actual function
        inner = fn
        while hasattr(inner, "__wrapped__"):
            inner = inner.__wrapped__
        sig = inspect.signature(inner)
        assert "project" not in sig.parameters, f"Tool {name} should not have a 'project' parameter"


# ── memory_store ──────────────────────────────────────────────────


async def test_memory_store():
    """memory_store stores a memory and returns JSON with memory_id."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_store"](
            memory_type="incident",
            summary="Restarted monitoring-server",
            trigger="health_loop",
            outcome="resolved",
        )

    data = json.loads(result)
    assert data["project"] == "monitoring"
    assert data["memory_id"] == 42
    assert data["stored"] is True
    mock_store.store_memory.assert_called_once()
    call_kwargs = mock_store.store_memory.call_args[1]
    assert call_kwargs["project"] == "monitoring"
    assert call_kwargs["memory_type"] == "incident"


# ── memory_recall_recent ──────────────────────────────────────────


async def test_memory_recall_recent_empty():
    """memory_recall_recent returns empty list when no memories."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_recent"]()

    data = json.loads(result)
    assert data["project"] == "monitoring"
    assert data["count"] == 0
    assert data["memories"] == []


async def test_memory_recall_recent_with_memories():
    """memory_recall_recent returns formatted memories."""
    mcp, mock_store = _make_mcp_with_tools()
    mem = MagicMock()
    mem.id = 1
    mem.memory_type = "incident"
    mem.summary = "Restarted"
    mem.outcome = "resolved"
    mem.trigger = "health_loop"
    mem.created_at = None
    mock_store.recall_recent = AsyncMock(return_value=[mem])

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_recent"](limit=5)

    data = json.loads(result)
    assert data["count"] == 1
    assert data["memories"][0]["summary"] == "Restarted"


async def test_memory_recall_recent_limit_capped():
    """Limit is capped at 50."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        await mcp.tools_registered["memory_recall_recent"](limit=100)

    call_kwargs = mock_store.recall_recent.call_args[1]
    assert call_kwargs["limit"] == 50


# ── memory_recall_similar ─────────────────────────────────────────


async def test_memory_recall_similar_qdrant_unavailable():
    """memory_recall_similar handles Qdrant being unavailable."""
    mcp, mock_store = _make_mcp_with_tools()
    mock_store.recall_similar = AsyncMock(return_value=None)

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_similar"](query="test")

    data = json.loads(result)
    assert "error" in data
    assert data["count"] == 0


async def test_memory_recall_similar_with_results():
    """memory_recall_similar returns scored memories."""
    mcp, mock_store = _make_mcp_with_tools()
    mem = MagicMock()
    mem.id = 5
    mem.memory_type = "incident"
    mem.summary = "Similar event"
    mem.outcome = "resolved"
    mem.score = 0.87
    mem.created_at = None
    mock_store.recall_similar = AsyncMock(return_value=[mem])

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_similar"](query="monitoring OOM")

    data = json.loads(result)
    assert data["count"] == 1
    assert data["memories"][0]["score"] == 0.87


# ── memory_recall_by_id ──────────────────────────────────────────


async def test_memory_recall_by_id_not_found():
    """memory_recall_by_id returns error when not found."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_by_id"](memory_id=999)

    data = json.loads(result)
    assert "error" in data
    assert "999" in data["error"]


async def test_memory_recall_by_id_found():
    """memory_recall_by_id returns memory when found."""
    mcp, mock_store = _make_mcp_with_tools()
    mem = MagicMock()
    mem.id = 42
    mem.memory_type = "incident"
    mem.summary = "Found it"
    mem.outcome = "resolved"
    mem.trigger = "test"
    mem.reasoning = "analysis"
    mem.created_at = None
    mock_store.recall_by_id = AsyncMock(return_value=mem)

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_recall_by_id"](memory_id=42)

    data = json.loads(result)
    assert data["memory"]["id"] == 42
    assert data["memory"]["summary"] == "Found it"


# ── memory_embed ──────────────────────────────────────────────────


async def test_memory_embed():
    """memory_embed embeds a memory into Qdrant."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_embed"](
            memory_id=42,
            summary="Test embedding",
        )

    data = json.loads(result)
    assert data["embedded"] is True
    mock_store.embed_and_store.assert_called_once()


# ── memory_save ───────────────────────────────────────────────────


async def test_memory_save_pg_and_qdrant():
    """memory_save stores to PG then embeds in Qdrant."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_save"](
            memory_type="pattern",
            summary="Learned a new pattern",
            outcome="resolved",
        )

    data = json.loads(result)
    assert data["pg_stored"] is True
    assert data["qdrant_embedded"] is True
    assert data["memory_id"] == 42
    mock_store.store_memory.assert_called_once()
    mock_store.embed_and_store.assert_called_once()


async def test_memory_save_pg_fails():
    """memory_save gracefully handles PG failure (no Qdrant attempt)."""
    mcp, mock_store = _make_mcp_with_tools()
    mock_store.store_memory = AsyncMock(return_value=None)

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_save"](
            memory_type="incident",
            summary="Test",
        )

    data = json.loads(result)
    assert data["pg_stored"] is False
    assert "qdrant_embedded" not in data
    mock_store.embed_and_store.assert_not_called()


# ── memory_brief ──────────────────────────────────────────────────


async def test_memory_brief_empty():
    """memory_brief returns empty tiers when no memories."""
    mcp, mock_store = _make_mcp_with_tools()

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_brief"]()

    data = json.loads(result)
    assert data["tier2_recent_count"] == 0
    assert data["tier3_similar_count"] == 0


async def test_memory_brief_with_recent_triggers_similar():
    """memory_brief uses most recent summary as Qdrant query."""
    mcp, mock_store = _make_mcp_with_tools()
    mem = MagicMock()
    mem.id = 1
    mem.memory_type = "incident"
    mem.summary = "Grafana OOM restart"
    mem.outcome = "resolved"
    mem.created_at = None
    mock_store.recall_recent = AsyncMock(return_value=[mem])

    similar_mem = MagicMock()
    similar_mem.id = 2
    similar_mem.memory_type = "incident"
    similar_mem.summary = "Previous OOM"
    similar_mem.outcome = "resolved"
    similar_mem.score = 0.85
    similar_mem.created_at = None
    mock_store.recall_similar = AsyncMock(return_value=[similar_mem])

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_brief"]()

    data = json.loads(result)
    assert data["tier2_recent_count"] == 1
    assert data["tier3_similar_count"] == 1
    # Confirm the query was the most recent summary
    call_kwargs = mock_store.recall_similar.call_args[1]
    assert call_kwargs["query_text"] == "Grafana OOM restart"


# ── memory_load_knowledge ─────────────────────────────────────────


async def test_memory_load_knowledge_dir_missing(tmp_path: Path):
    """memory_load_knowledge returns error when dir doesn't exist."""
    mcp, _ = _make_mcp_with_tools(knowledge_dir=tmp_path / "nonexistent")

    result = await mcp.tools_registered["memory_load_knowledge"]()

    data = json.loads(result)
    assert "error" in data
    assert data["files"] == []


async def test_memory_load_knowledge_reads_md_files(tmp_path: Path):
    """memory_load_knowledge reads .md files from knowledge dir."""
    knowledge_dir = tmp_path / "knowledge"
    knowledge_dir.mkdir()
    (knowledge_dir / "identity.md").write_text("I am Room 100.")
    skills = knowledge_dir / "skills"
    skills.mkdir()
    (skills / "health.md").write_text("# Health\nCheck service first.")

    mcp, _ = _make_mcp_with_tools(knowledge_dir=knowledge_dir)

    result = await mcp.tools_registered["memory_load_knowledge"]()

    data = json.loads(result)
    assert data["file_count"] == 2
    assert "identity.md" in data["files"]
    assert "skills/health.md" in data["files"]
    assert "I am Room 100." in data["content"]
    assert "Check service first." in data["content"]


# ── Project binding via closure ───────────────────────────────────


async def test_project_binding_different_rooms():
    """Two rooms registered on different MCPs use their own project name."""
    mcp1, store1 = _make_mcp_with_tools(project="monitoring")
    mcp2, store2 = _make_mcp_with_tools(project="my-service")

    with patch("maude.memory.memory_tools._get_store", return_value=store1):
        result1 = await mcp1.tools_registered["memory_store"](
            memory_type="check",
            summary="test1",
        )
    with patch("maude.memory.memory_tools._get_store", return_value=store2):
        result2 = await mcp2.tools_registered["memory_store"](
            memory_type="check",
            summary="test2",
        )

    assert json.loads(result1)["project"] == "monitoring"
    assert json.loads(result2)["project"] == "my-service"


# ── Graceful degradation ──────────────────────────────────────────


async def test_memory_store_pg_returns_none():
    """memory_store handles PG returning None gracefully."""
    mcp, mock_store = _make_mcp_with_tools()
    mock_store.store_memory = AsyncMock(return_value=None)

    with patch("maude.memory.memory_tools._get_store", return_value=mock_store):
        result = await mcp.tools_registered["memory_store"](
            memory_type="check",
            summary="test",
        )

    data = json.loads(result)
    assert data["stored"] is False
    assert data["memory_id"] is None
