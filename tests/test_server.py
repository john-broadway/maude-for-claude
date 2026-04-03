# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Coordination MCP server — tool functions with mocked components."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination import server

# FastMCP @mcp.tool() wraps functions in FunctionTool objects.
# In FastMCP 3.x these live in mcp.local_provider._components keyed as "tool:{name}@".
try:
    _components = server.mcp.local_provider._components
    _briefing_fn = _components["tool:coordinator_briefing@"].fn
    _room_status_fn = _components["tool:coordinator_room_status@"].fn
    _dep_graph_fn = _components["tool:coordinator_dependency_graph@"].fn
    _incidents_fn = _components["tool:coordinator_recent_incidents@"].fn
    _escalations_fn = _components["tool:coordinator_recent_escalations@"].fn
    _ecosystem_fn = _components["tool:coordinator_ecosystem_map@"].fn
except (AttributeError, KeyError):
    _briefing_fn = None
    _room_status_fn = None
    _dep_graph_fn = None
    _incidents_fn = None
    _escalations_fn = None
    _ecosystem_fn = None


@pytest.fixture(autouse=True)
def _reset_server_globals():
    """Reset lazy-init globals between tests."""
    server._memory = None
    server._deps = None
    server._briefing = None
    yield
    server._memory = None
    server._deps = None
    server._briefing = None


@pytest.fixture
def mock_components():
    """Set module globals so _get_components() returns mocks."""
    mock_memory = AsyncMock()
    # DependencyGraph methods are sync — use MagicMock, not AsyncMock
    mock_deps = MagicMock()
    mock_deps.depends_on.return_value = ["postgresql"]
    mock_deps.depended_by.return_value = ["hmi"]
    mock_deps.affected_by.return_value = ["postgresql"]
    mock_deps.to_dict.return_value = {"my-service": {"depends_on": ["postgresql"]}}
    mock_deps.to_ecosystem_dict.return_value = {"rooms": [], "layers": []}

    mock_briefing = AsyncMock()
    mock_briefing.generate = AsyncMock(return_value="== Briefing ==")
    mock_briefing.room_status = AsyncMock(return_value="ROOM STATUS GRID")

    # Set module globals directly — _get_components() returns them
    # since they're not None (skips lazy init)
    server._memory = mock_memory
    server._deps = mock_deps
    server._briefing = mock_briefing
    yield mock_memory, mock_deps, mock_briefing


# ── coordinator_briefing ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_briefing_defaults(mock_components: tuple):
    _, _, mock_briefing = mock_components
    result = await _briefing_fn()
    mock_briefing.generate.assert_awaited_once_with(scope="site", minutes=60)
    assert result == "== Briefing =="


@pytest.mark.asyncio
async def test_briefing_custom_args(mock_components: tuple):
    _, _, mock_briefing = mock_components
    await _briefing_fn(scope="room:my-service", minutes=480)
    mock_briefing.generate.assert_awaited_once_with(scope="room:my-service", minutes=480)


# ── coordinator_room_status ───────────────────────────────────────


@pytest.mark.asyncio
async def test_room_status(mock_components: tuple):
    _, _, mock_briefing = mock_components
    result = await _room_status_fn(minutes=30)
    mock_briefing.room_status.assert_awaited_once_with(minutes=30)
    assert "ROOM STATUS GRID" in result


# ── coordinator_dependency_graph ──────────────────────────────────


@pytest.mark.asyncio
async def test_dependency_graph_full(mock_components: tuple):
    _, mock_deps, _ = mock_components
    result = await _dep_graph_fn()
    data = json.loads(result)
    assert "my-service" in data
    mock_deps.to_dict.assert_called_once()


@pytest.mark.asyncio
async def test_dependency_graph_single_room(mock_components: tuple):
    _, mock_deps, _ = mock_components
    result = await _dep_graph_fn(room="my-service")
    data = json.loads(result)
    assert data["room"] == "my-service"
    assert "postgresql" in data["depends_on"]
    mock_deps.depends_on.assert_called_once_with("my-service")
    mock_deps.depended_by.assert_called_once_with("my-service")
    mock_deps.affected_by.assert_called_once_with("my-service")


# ── coordinator_recent_incidents ──────────────────────────────────


@pytest.mark.asyncio
async def test_incidents_empty(mock_components: tuple):
    mock_memory, _, _ = mock_components
    mock_memory.recent_incidents = AsyncMock(return_value=[])
    result = await _incidents_fn(minutes=60)
    data = json.loads(result)
    assert data == []


@pytest.mark.asyncio
async def test_incidents_with_data(mock_components: tuple):
    mock_memory, _, _ = mock_components
    mock_memory.recent_incidents = AsyncMock(
        return_value=[
            {"project": "monitoring", "summary": "Datasource timeout", "outcome": "resolved"},
        ]
    )
    result = await _incidents_fn(minutes=120)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["project"] == "monitoring"


# ── coordinator_recent_escalations ────────────────────────────────


@pytest.mark.asyncio
async def test_escalations_empty(mock_components: tuple):
    mock_memory, _, _ = mock_components
    mock_memory.recent_escalations = AsyncMock(return_value=[])
    result = await _escalations_fn()
    data = json.loads(result)
    assert data == []


@pytest.mark.asyncio
async def test_escalations_with_data(mock_components: tuple):
    mock_memory, _, _ = mock_components
    mock_memory.recent_escalations = AsyncMock(
        return_value=[
            {"project": "my-service", "summary": "Service unreachable"},
        ]
    )
    result = await _escalations_fn(minutes=30)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["project"] == "my-service"


# ── coordinator_ecosystem_map ────────────────────────────────────


@pytest.mark.asyncio
async def test_ecosystem_map(mock_components: tuple):
    _, mock_deps, _ = mock_components
    result = await _ecosystem_fn()
    data = json.loads(result)
    assert "rooms" in data
    mock_deps.to_ecosystem_dict.assert_called_once()


# ── Lazy init ────────────────────────────────────────────────────


def test_get_components_lazy_init():
    """_get_components should create singletons on first call."""
    with (
        patch("maude.coordination.server.CrossRoomMemory") as MockMem,
        patch("maude.coordination.server.DependencyGraph") as MockDeps,
        patch("maude.coordination.server.BriefingGenerator") as MockBrief,
    ):
        mem, deps, brief = server._get_components()
        assert mem is MockMem.return_value
        assert deps is MockDeps.return_value
        assert brief is MockBrief.return_value

        # Second call should return same instances
        mem2, deps2, brief2 = server._get_components()
        assert mem2 is mem
        MockMem.assert_called_once()


def test_get_components_reuses_instances():
    """Subsequent calls should not re-create components."""
    with (
        patch("maude.coordination.server.CrossRoomMemory") as MockMem,
        patch("maude.coordination.server.DependencyGraph") as MockDeps,
        patch("maude.coordination.server.BriefingGenerator") as MockBrief,
    ):
        server._get_components()
        server._get_components()
        server._get_components()
        # Each should only be instantiated once
        assert MockMem.call_count == 1
        assert MockDeps.call_count == 1
        assert MockBrief.call_count == 1
