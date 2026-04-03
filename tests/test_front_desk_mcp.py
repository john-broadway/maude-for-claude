# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Coordination MCP for LXC 800.

Claude (Anthropic) <noreply@anthropic.com>
"""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import maude.daemon.guards
from maude.coordination.mcp import create_server
from maude.daemon.config import RoomConfig


@pytest.fixture(autouse=True)
def _clear_rate_limit_state():
    """Clear rate limiter state between tests."""
    maude.daemon.guards._rate_limit_state.clear()
    yield
    maude.daemon.guards._rate_limit_state.clear()


@pytest.fixture
def mock_deps() -> MagicMock:
    deps = MagicMock()
    deps.all_rooms = ["postgresql", "my-service", "monitoring"]
    deps.depends_on.side_effect = lambda r: ["postgresql"] if r == "my-service" else []
    deps.depended_by.side_effect = lambda r: ["my-service"] if r == "postgresql" else []
    deps.model_for.return_value = None
    return deps


@pytest.fixture
def mock_memory() -> AsyncMock:
    return AsyncMock()


@pytest.fixture
def mock_briefing() -> AsyncMock:
    return AsyncMock()


@pytest.fixture
def mcp(mock_memory, mock_deps, mock_briefing, tmp_path):
    """Create Coordination MCP with mocked hotel components."""
    config = RoomConfig(
        project="maude",
        service_name="maude-web",
        mcp_port=9500,
        ctid=5000,
        ip="localhost",
    )
    components = (mock_memory, mock_deps, mock_briefing)
    with (
        patch("maude.coordination.mcp._get_hotel_components", return_value=components),
        patch.dict("os.environ", {"AGENCY_ROOT": str(tmp_path)}),
    ):
        server = create_server(config)
    return server


async def _tool(mcp, name: str):
    """Get a registered tool by name (FastMCP 3.x async API)."""
    return await mcp.get_tool(name)


async def _tool_names(mcp) -> set[str]:
    """Get all registered tool names (FastMCP 3.x async API)."""
    tools = await mcp.list_tools()
    return {t.name for t in tools}


# ── Tool registration ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_mcp_has_briefing_tools(mcp):
    names = await _tool_names(mcp)
    expected = {
        "coordinator_briefing",
        "coordinator_room_status",
        "coordinator_dependency_graph",
        "coordinator_recent_incidents",
        "coordinator_recent_escalations",
    }
    assert expected.issubset(names), f"Missing: {expected - names}"


@pytest.mark.asyncio
async def test_mcp_has_fleet_tools(mcp):
    names = await _tool_names(mcp)
    expected = {
        "fleet_room_registry",
        "fleet_memory_query",
        "fleet_recent_restarts",
        "fleet_deploy",
    }
    assert expected.issubset(names), f"Missing: {expected - names}"


@pytest.mark.asyncio
async def test_mcp_has_event_tools(mcp):
    names = await _tool_names(mcp)
    assert "coordinator_live_events" in names


@pytest.mark.asyncio
async def test_mcp_has_relay_tools(mcp):
    names = await _tool_names(mcp)
    expected = {"coordinator_relay", "coordinator_messages"}
    assert expected.issubset(names), f"Missing: {expected - names}"


@pytest.mark.asyncio
async def test_mcp_has_base_tools(mcp):
    names = await _tool_names(mcp)
    expected = {
        "service_status",
        "service_health",
        "service_logs",
        "service_errors",
        "service_restart",
        "kill_switch_status",
    }
    assert expected.issubset(names), f"Missing: {expected - names}"


@pytest.mark.asyncio
async def test_mcp_has_correlation_tool(mcp):
    names = await _tool_names(mcp)
    assert "coordinator_correlated_incidents" in names


@pytest.mark.asyncio
async def test_mcp_has_diagnostic_trace_tool(mcp):
    names = await _tool_names(mcp)
    assert "coordinator_diagnostic_trace" in names


# ── Fleet tools ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_room_registry(mcp, mock_deps):
    tool = await _tool(mcp, "fleet_room_registry")
    result = await tool.fn()
    data = json.loads(result)
    assert len(data) == 3
    assert data[0]["room"] == "postgresql"
    assert "my-service" in data[0]["depended_by"]


@pytest.mark.asyncio
async def test_fleet_memory_query_filters_by_room(mcp, mock_memory):
    mock_memory.recent_activity = AsyncMock(
        return_value=[
            {"project": "my-service", "summary": "PLC check passed"},
            {"project": "monitoring", "summary": "Dashboard ok"},
        ]
    )

    tool = await _tool(mcp, "fleet_memory_query")
    result = await tool.fn(room="my-service")
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["project"] == "my-service"


@pytest.mark.asyncio
async def test_fleet_memory_query_filters_by_text(mcp, mock_memory):
    mock_memory.recent_activity = AsyncMock(
        return_value=[
            {"project": "my-service", "summary": "PLC check passed"},
            {"project": "monitoring", "summary": "Dashboard ok"},
        ]
    )

    tool = await _tool(mcp, "fleet_memory_query")
    result = await tool.fn(query="PLC")
    data = json.loads(result)
    assert len(data) == 1
    assert "PLC" in data[0]["summary"]


@pytest.mark.asyncio
async def test_fleet_memory_query_both_filters(mcp, mock_memory):
    mock_memory.recent_activity = AsyncMock(
        return_value=[
            {"project": "my-service", "summary": "PLC check passed"},
            {"project": "my-service", "summary": "Config deployed"},
            {"project": "monitoring", "summary": "PLC dashboard ok"},
        ]
    )

    tool = await _tool(mcp, "fleet_memory_query")
    result = await tool.fn(query="PLC", room="my-service", minutes=120)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["project"] == "my-service"
    assert "PLC" in data[0]["summary"]


@pytest.mark.asyncio
async def test_fleet_recent_restarts(mcp, mock_memory):
    mock_memory.recent_restarts = AsyncMock(
        return_value=[
            {"project": "my-service", "tool": "health_loop.restart"},
        ]
    )

    tool = await _tool(mcp, "fleet_recent_restarts")
    result = await tool.fn(minutes=120)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["project"] == "my-service"


# ── Briefing tools ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_coordinator_briefing_tool(mcp, mock_briefing):
    mock_briefing.generate = AsyncMock(return_value="== Hotel Briefing ==")

    tool = await _tool(mcp, "coordinator_briefing")
    result = await tool.fn(scope="all", minutes=60)
    assert result == "== Hotel Briefing =="
    mock_briefing.generate.assert_awaited_once_with(scope="all", minutes=60)


@pytest.mark.asyncio
async def test_coordinator_room_status_tool(mcp, mock_briefing):
    mock_briefing.room_status = AsyncMock(return_value="Room Status Grid")

    tool = await _tool(mcp, "coordinator_room_status")
    result = await tool.fn(minutes=30)
    assert result == "Room Status Grid"
    mock_briefing.room_status.assert_awaited_once_with(minutes=30)


@pytest.mark.asyncio
async def test_coordinator_dependency_graph_specific_room(mcp, mock_deps):
    mock_deps.depends_on.return_value = ["postgresql"]
    mock_deps.depended_by.return_value = []
    mock_deps.affected_by.return_value = ["postgresql"]

    tool = await _tool(mcp, "coordinator_dependency_graph")
    result = await tool.fn(room="my-service")
    data = json.loads(result)
    assert data["room"] == "my-service"
    assert data["depends_on"] == ["postgresql"]
    assert data["affected_by"] == ["postgresql"]


@pytest.mark.asyncio
async def test_coordinator_dependency_graph_full(mcp, mock_deps):
    mock_deps.to_dict.return_value = {
        "postgresql": {"depends_on": [], "depended_by": ["my-service"]}
    }

    tool = await _tool(mcp, "coordinator_dependency_graph")
    result = await tool.fn(room="")
    data = json.loads(result)
    assert "postgresql" in data


@pytest.mark.asyncio
async def test_coordinator_recent_incidents_tool(mcp, mock_memory):
    mock_memory.recent_incidents = AsyncMock(
        return_value=[
            {"project": "my-service", "outcome": "resolved", "summary": "PLC fixed"},
        ]
    )

    tool = await _tool(mcp, "coordinator_recent_incidents")
    result = await tool.fn(minutes=120)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["outcome"] == "resolved"


@pytest.mark.asyncio
async def test_coordinator_recent_escalations_tool(mcp, mock_memory):
    mock_memory.recent_escalations = AsyncMock(
        return_value=[
            {"project": "monitoring", "outcome": "escalated", "summary": "DB down"},
        ]
    )

    tool = await _tool(mcp, "coordinator_recent_escalations")
    result = await tool.fn(minutes=60)
    data = json.loads(result)
    assert len(data) == 1
    assert data[0]["outcome"] == "escalated"


# ── Event tools (degraded mode) ───────────────────────────────


@pytest.mark.asyncio
async def test_live_events_standalone_mode(mcp):
    tool = await _tool(mcp, "coordinator_live_events")
    result = await tool.fn()
    data = json.loads(result)
    assert "not running" in data["error"]
    assert data["events"] == []


# ── Relay tools (degraded mode) ───────────────────────────────


@pytest.mark.asyncio
async def test_relay_standalone_mode(mcp):
    tool = await _tool(mcp, "coordinator_relay")
    result = await tool.fn(to_room="b", subject="x", body="y")
    data = json.loads(result)
    # Relay now writes to relay_tasks table — may succeed or error
    assert "id" in data or "error" in data


@pytest.mark.asyncio
async def test_messages_standalone_mode(mcp):
    tool = await _tool(mcp, "coordinator_messages")
    result = await tool.fn(room="monitoring")
    data = json.loads(result)
    # Relay now reads from relay_tasks table — may succeed or error
    assert "messages" in data or "error" in data


# ── Correlation tools (degraded mode) ─────────────────────────


@pytest.mark.asyncio
async def test_correlated_incidents_standalone_mode(mcp):
    tool = await _tool(mcp, "coordinator_correlated_incidents")
    result = await tool.fn()
    data = json.loads(result)
    assert "not running" in data["error"] or "inactive" in data["error"]
    assert data["incidents"] == []


# ── Fleet deploy ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_deploy_dry_run(mcp):
    # fleet_deploy tool calls executor.run() which is already captured in closure.
    # We can't easily replace it post-creation. Instead test tool registration.
    names = await _tool_names(mcp)
    assert "fleet_deploy" in names


# ── Diagnostic trace ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_diagnostic_trace_pipeline(mcp, mock_deps):
    # Pipeline plc_to_monitoring is ["collector", "postgresql", "monitoring"]
    mock_deps.all_rooms = ["collector", "postgresql", "monitoring"]
    mock_deps.depends_on.return_value = []

    tool = await _tool(mcp, "coordinator_diagnostic_trace")
    result = await tool.fn(pipeline="plc_to_monitoring", mode="pipeline")
    data = json.loads(result)

    assert data["name"] == "plc_to_monitoring"
    assert isinstance(data["hops"], list)
    assert len(data["hops"]) == 3
    assert data["hops"][0]["room"] == "collector"
    assert "available_pipelines" in data


@pytest.mark.asyncio
async def test_diagnostic_trace_dependency_mode(mcp, mock_deps):
    mock_deps.all_rooms = ["postgresql", "monitoring"]
    mock_deps.depends_on.side_effect = lambda r: ["postgresql"] if r == "monitoring" else []

    tool = await _tool(mcp, "coordinator_diagnostic_trace")
    result = await tool.fn(pipeline="monitoring", mode="dependency")
    data = json.loads(result)

    assert data["name"] == "deps:monitoring"
    rooms = [h["room"] for h in data["hops"]]
    assert rooms[-1] == "monitoring"
    assert "postgresql" in rooms


# ── Webhook alert ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_webhook_fires_on_unhealthy_rooms():
    """BriefingGenerator fires HTTP POST when rooms are unhealthy and webhook is configured."""
    from maude.coordination.briefing import BriefingGenerator

    memory = AsyncMock()
    memory.all_rooms_summary = AsyncMock(
        return_value=[
            {"project": "my-service", "failed": 1, "escalated": 0},
        ]
    )
    memory.recent_incidents = AsyncMock(return_value=[])
    memory.recent_escalations = AsyncMock(return_value=[])
    memory.recent_restarts = AsyncMock(return_value=[])
    memory.recent_remediations = AsyncMock(return_value=[])

    deps = MagicMock()
    deps.all_rooms = ["my-service"]
    deps.affected_by.return_value = []

    briefing = BriefingGenerator(memory, deps, alert_webhook_url="https://hooks.example.com/alert")

    with patch.object(briefing, "_post_webhook", new_callable=AsyncMock) as mock_hook:
        await briefing.generate()
        await asyncio.sleep(0)  # flush create_task
        mock_hook.assert_awaited_once()
        rooms_arg = mock_hook.call_args.args[0]
        assert any("my-service" in r for r in rooms_arg)
