# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Maude memory-as-a-service tools."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastmcp import FastMCP

from maude.coordination._memory_tools import register_memory_tools


class _NullAudit:
    async def log_tool_call(self, **kwargs):
        pass


@pytest.fixture
def mcp_server():
    """Create a FastMCP instance with memory tools registered."""
    mcp = FastMCP(name="test-memory")
    register_memory_tools(mcp, _NullAudit())
    return mcp


def _mock_memory(
    id: int = 1,
    project: str = "redis",
    memory_type: str = "incident",
    summary: str = "test",
    outcome: str = "resolved",
    trigger: str = "",
    score: float = 0.0,
    created_at=None,
):
    m = MagicMock()
    m.id = id
    m.project = project
    m.memory_type = memory_type
    m.summary = summary
    m.outcome = outcome
    m.trigger = trigger
    m.score = score
    m.created_at = created_at
    return m


@pytest.mark.asyncio
async def test_maude_memory_store(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.store_memory = AsyncMock(return_value=42)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_store",
            {
                "project": "redis",
                "memory_type": "incident",
                "summary": "Redis OOM",
            },
        )
        data = json.loads(result.content[0].text)
        assert data["project"] == "redis"
        assert data["memory_id"] == 42
        assert data["stored"] is True


@pytest.mark.asyncio
async def test_maude_memory_recall_recent(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.recall_recent = AsyncMock(
        return_value=[
            _mock_memory(id=1, summary="event A"),
            _mock_memory(id=2, summary="event B"),
        ]
    )

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_recall_recent",
            {"project": "redis", "limit": 5},
        )
        data = json.loads(result.content[0].text)
        assert data["count"] == 2
        assert data["memories"][0]["summary"] == "event A"


@pytest.mark.asyncio
async def test_maude_memory_recall_similar(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.recall_similar = AsyncMock(
        return_value=[
            _mock_memory(id=3, summary="similar event", score=0.875),
        ]
    )

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_recall_similar",
            {"project": "redis", "query": "oom error"},
        )
        data = json.loads(result.content[0].text)
        assert data["count"] == 1
        assert data["memories"][0]["score"] == 0.875


@pytest.mark.asyncio
async def test_maude_memory_recall_similar_qdrant_down(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.recall_similar = AsyncMock(return_value=None)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_recall_similar",
            {"project": "redis", "query": "oom"},
        )
        data = json.loads(result.content[0].text)
        assert "error" in data
        assert data["count"] == 0


@pytest.mark.asyncio
async def test_maude_memory_embed(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.embed_and_store = AsyncMock(return_value=True)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_embed",
            {"project": "redis", "memory_id": 42, "summary": "Redis OOM"},
        )
        data = json.loads(result.content[0].text)
        assert data["embedded"] is True


@pytest.mark.asyncio
async def test_maude_memory_save(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.store_memory = AsyncMock(return_value=99)
    mock_store.embed_and_store = AsyncMock(return_value=True)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_save",
            {
                "project": "redis",
                "memory_type": "incident",
                "summary": "Redis OOM resolved",
                "outcome": "resolved",
            },
        )
        data = json.loads(result.content[0].text)
        assert data["pg_stored"] is True
        assert data["memory_id"] == 99
        assert data["qdrant_embedded"] is True


@pytest.mark.asyncio
async def test_maude_memory_brief(mcp_server: FastMCP) -> None:
    recent_mem = _mock_memory(id=1, summary="recent event")
    similar_mem = _mock_memory(id=2, summary="similar event", score=0.8)

    mock_store = MagicMock()
    mock_store.recall_recent = AsyncMock(return_value=[recent_mem])
    mock_store.recall_similar = AsyncMock(return_value=[similar_mem])

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_brief",
            {"project": "redis"},
        )
        data = json.loads(result.content[0].text)
        assert data["tier2_recent_count"] == 1
        assert data["tier3_similar_count"] == 1
        assert data["tier3_similar"][0]["score"] == 0.8


@pytest.mark.asyncio
async def test_maude_memory_recall_by_id(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_mem = _mock_memory(id=42, summary="found it", outcome="resolved")
    mock_mem.project = "redis"
    mock_mem.reasoning = "checked logs"
    mock_mem.tokens_used = 100
    mock_mem.model = "qwen3"
    mock_store.recall_by_id = AsyncMock(return_value=mock_mem)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_recall_by_id",
            {"project": "redis", "memory_id": 42},
        )
        data = json.loads(result.content[0].text)
        assert data["memory"]["id"] == 42
        assert data["memory"]["summary"] == "found it"
        assert data["memory"]["reasoning"] == "checked logs"


@pytest.mark.asyncio
async def test_maude_memory_recall_by_id_not_found(mcp_server: FastMCP) -> None:
    mock_store = MagicMock()
    mock_store.recall_by_id = AsyncMock(return_value=None)

    with patch("maude.coordination._memory_tools._get_store", return_value=mock_store):
        result = await mcp_server.call_tool(
            "maude_memory_recall_by_id",
            {"project": "redis", "memory_id": 999},
        )
        data = json.loads(result.content[0].text)
        assert "error" in data
        assert data["id"] == 999


@pytest.mark.asyncio
async def test_maude_memory_load_knowledge(mcp_server: FastMCP, tmp_path) -> None:
    # Create a fake knowledge dir with content
    knowledge_dir = tmp_path / "knowledge"
    knowledge_dir.mkdir()
    (knowledge_dir / "identity.md").write_text("I am redis room agent.")

    mock_km = MagicMock()
    mock_km.knowledge_dir = knowledge_dir
    mock_km.load_knowledge = AsyncMock(return_value="# Identity\n\nI am redis room agent.")

    with patch("maude.coordination._memory_tools._get_knowledge_manager", return_value=mock_km):
        result = await mcp_server.call_tool(
            "maude_memory_load_knowledge",
            {"project": "redis"},
        )
        data = json.loads(result.content[0].text)
        assert data["project"] == "redis"
        assert data["chars"] > 0
        assert "Identity" in data["content"]


@pytest.mark.asyncio
async def test_maude_memory_load_knowledge_no_dir(mcp_server: FastMCP, tmp_path) -> None:
    mock_km = MagicMock()
    mock_km.knowledge_dir = tmp_path / "nonexistent"

    with patch("maude.coordination._memory_tools._get_knowledge_manager", return_value=mock_km):
        result = await mcp_server.call_tool(
            "maude_memory_load_knowledge",
            {"project": "fakefake"},
        )
        data = json.loads(result.content[0].text)
        assert "error" in data


@pytest.mark.asyncio
async def test_maude_memory_update_knowledge(mcp_server: FastMCP, tmp_path) -> None:
    mock_km = MagicMock()
    mock_km.knowledge_dir = tmp_path / "knowledge"
    mock_km.update_memory = AsyncMock(return_value=True)

    with patch("maude.coordination._memory_tools._get_knowledge_manager", return_value=mock_km):
        result = await mcp_server.call_tool(
            "maude_memory_update_knowledge",
            {"project": "redis", "category": "incidents", "entry": "OOM at 3am"},
        )
        data = json.loads(result.content[0].text)
        assert data["success"] is True
        assert data["category"] == "incidents"


@pytest.mark.asyncio
async def test_maude_memory_list_projects(mcp_server: FastMCP, tmp_path) -> None:
    # Create fake project structure
    infra = tmp_path / "infrastructure" / "monitoring" / "knowledge"
    infra.mkdir(parents=True)
    plat = tmp_path / "infrastructure" / "maude" / "knowledge"
    plat.mkdir(parents=True)

    with patch("maude.coordination._memory_tools.PROJECTS_DIR", tmp_path):
        with patch(
            "maude.coordination._memory_tools._DOMAIN_GROUPS",
            ("industrial", "infrastructure", "apps"),
        ):
            result = await mcp_server.call_tool(
                "maude_memory_list_projects",
                {},
            )
            data = json.loads(result.content[0].text)
            assert "infrastructure/monitoring" in data["projects_with_knowledge"]
            assert "infrastructure/maude" in data["projects_with_knowledge"]


@pytest.mark.asyncio
async def test_all_ten_tools_registered(mcp_server: FastMCP) -> None:
    tools = await mcp_server.list_tools()
    tool_names = {t.name for t in tools}
    expected = {
        "maude_memory_store",
        "maude_memory_recall_recent",
        "maude_memory_recall_similar",
        "maude_memory_embed",
        "maude_memory_save",
        "maude_memory_brief",
        "maude_memory_recall_by_id",
        "maude_memory_load_knowledge",
        "maude_memory_update_knowledge",
        "maude_memory_list_projects",
    }
    assert expected.issubset(tool_names)
