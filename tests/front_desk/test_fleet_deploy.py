# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for fleet_deploy — fleet deployment orchestration tools."""

import json
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination.fleet_deploy import (
    MAUDE_REPO,
    register_fleet_deploy_tools,
    repo_to_rooms,
)
from maude.healing.dependencies import DependencyGraph
from maude.testing import FakeAudit, FakeKillSwitch, FakeMCP, reset_rate_limits

_FIXTURE_YAML = Path(__file__).parent.parent / "fixtures" / "dependencies.yaml"


@pytest.fixture(autouse=True)
def _clear_rate_limits():
    """Reset rate limit state before and after each test."""
    reset_rate_limits()
    yield
    reset_rate_limits()


@pytest.fixture
def graph() -> DependencyGraph:
    """Load the test fixture dependencies.yaml (not the empty production stub)."""
    return DependencyGraph(yaml_path=_FIXTURE_YAML)


@pytest.fixture
def fake_mcp() -> FakeMCP:
    return FakeMCP()


@pytest.fixture
def fake_audit() -> FakeAudit:
    return FakeAudit()


@pytest.fixture
def fake_kill_switch() -> FakeKillSwitch:
    return FakeKillSwitch(active=False)


@pytest.fixture
def get_components(graph: DependencyGraph):
    """Return a callable mimicking _get_hotel_components."""
    memory = MagicMock()
    briefing = MagicMock()
    return lambda: (memory, graph, briefing)


@pytest.fixture
def mock_publisher() -> AsyncMock:
    """Mock EventPublisher that accepts publish/connect calls."""
    pub = AsyncMock()
    pub.publish = AsyncMock(return_value=True)
    pub.connect = AsyncMock()
    return pub


@pytest.fixture
def mock_relay() -> MagicMock:
    """Mock Relay that accepts send calls."""
    relay = MagicMock()
    relay.send = AsyncMock(return_value=1)
    return relay


@pytest.fixture
def registered_tools(
    fake_mcp: FakeMCP,
    fake_audit: FakeAudit,
    fake_kill_switch: FakeKillSwitch,
    get_components,
    mock_publisher: AsyncMock,
    mock_relay: MagicMock,
) -> dict:
    """Register fleet deploy tools with injected mocks for publisher/relay."""
    register_fleet_deploy_tools(
        fake_mcp,
        fake_audit,
        fake_kill_switch,
        get_components,
        publisher=mock_publisher,
        relay=mock_relay,
    )
    return fake_mcp.tools


# ── repo_to_rooms() ──────────────────────────────────────────────


def test_repo_to_rooms(graph: DependencyGraph):
    """Mapping repo to rooms returns matching rooms."""
    rooms = repo_to_rooms(graph, "infrastructure/postgresql")
    names = [r["room"] for r in rooms]
    assert "postgresql" in names
    # SLC, PA, and SBM all have postgresql
    sites = [r["site"] for r in rooms]
    assert "site-a" in sites
    assert "site-b" in sites
    assert "site-c" in sites
    assert len(rooms) == 3


def test_repo_to_rooms_site_filter(graph: DependencyGraph):
    """Site filter narrows results to one site."""
    rooms = repo_to_rooms(graph, "infrastructure/postgresql", site="site-a")
    assert len(rooms) == 1
    assert rooms[0]["room"] == "postgresql"
    assert rooms[0]["site"] == "site-a"


def test_repo_to_rooms_maude(graph: DependencyGraph):
    """maude maps to ALL rooms (maude library update)."""
    rooms = repo_to_rooms(graph, MAUDE_REPO)
    all_room_count = len(graph.all_rooms)
    assert len(rooms) == all_room_count
    # Verify all sites represented
    sites = {r["site"] for r in rooms}
    assert "site-a" in sites
    assert "site-b" in sites
    assert "site-c" in sites


def test_repo_to_rooms_maude_site_filter(graph: DependencyGraph):
    """maude with site filter returns only that site's rooms."""
    rooms = repo_to_rooms(graph, MAUDE_REPO, site="site-b")
    assert all(r["site"] == "site-b" for r in rooms)
    assert len(rooms) == len(graph.rooms_by_site("site-b"))


def test_repo_to_rooms_unknown_repo(graph: DependencyGraph):
    """Unknown repo returns empty list."""
    rooms = repo_to_rooms(graph, "nonexistent/repo")
    assert rooms == []


def test_repo_to_rooms_example_scada_collector(graph: DependencyGraph):
    """industrial/example-scada/my-service maps to my-service rooms at both sites."""
    rooms = repo_to_rooms(graph, "industrial/example-scada/my-service")
    names = [r["room"] for r in rooms]
    assert all(n == "my-service" for n in names)
    assert len(rooms) == 3  # SLC + PA + SBM


def test_repo_to_rooms_includes_metadata(graph: DependencyGraph):
    """Each returned room dict has ip and mcp_port."""
    rooms = repo_to_rooms(graph, "infrastructure/postgresql", site="site-a")
    assert len(rooms) == 1
    room = rooms[0]
    assert room["ip"] == "localhost"
    assert room["mcp_port"] == 9201
    assert room["qualified"] == "site-a/postgresql"


# ── Tool registration ─────────────────────────────────────────────


def test_tools_registered(registered_tools: dict):
    """All three fleet deploy tools are registered."""
    assert "fleet_deploy_signal" in registered_tools
    assert "fleet_deploy_status" in registered_tools
    assert "fleet_maude_update" in registered_tools


# ── fleet_deploy_signal — success ─────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_deploy_signal_success(
    registered_tools: dict,
    mock_publisher: AsyncMock,
    mock_relay: MagicMock,
):
    """Successful deploy signal sends events and relay messages."""
    tool = registered_tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="infrastructure/postgresql",
        site="site-a",
        rooms="",
        confirm=True,
        reason="Updated health check logic",
    )

    result = json.loads(result_str)
    assert result["action"] == "fleet_deploy_signal"
    assert result["repo"] == "infrastructure/postgresql"
    assert result["status"] == "success"
    assert result["total"] >= 1
    assert result["signals_sent"][0]["room"] == "postgresql"
    assert result["signals_sent"][0]["event"] is True
    assert result["signals_sent"][0]["relay"] is True


@pytest.mark.asyncio
async def test_fleet_deploy_signal_maude_uses_self_update(
    registered_tools: dict,
    mock_publisher: AsyncMock,
):
    """When repo is maude, action should be self_update."""
    tool = registered_tools["fleet_deploy_signal"]

    result_str = await tool(
        repo=MAUDE_REPO,
        site="site-a",
        rooms="",
        confirm=True,
        reason="Maude library update",
    )

    result = json.loads(result_str)
    assert result["status"] == "success"
    assert result["total"] > 0

    # Verify publisher was called with self_update action
    publish_calls = mock_publisher.publish.call_args_list
    for call in publish_calls:
        assert call[0][0] == "deploy_requested"
        assert call[0][1]["action"] == "self_update"


@pytest.mark.asyncio
async def test_fleet_deploy_signal_explicit_rooms(
    registered_tools: dict,
    mock_publisher: AsyncMock,
    mock_relay: MagicMock,
):
    """Explicit room list overrides repo-based resolution."""
    tool = registered_tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="infrastructure/postgresql",
        site="",
        rooms="my-service,monitoring",
        confirm=True,
        reason="Test explicit rooms",
    )

    result = json.loads(result_str)
    assert result["status"] == "success"
    room_names = [s["room"] for s in result["signals_sent"]]
    assert "my-service" in room_names
    assert "monitoring" in room_names


@pytest.mark.asyncio
async def test_fleet_deploy_signal_no_targets(registered_tools: dict):
    """Unknown repo returns no_targets status."""
    tool = registered_tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="nonexistent/repo",
        site="",
        rooms="",
        confirm=True,
        reason="Should fail",
    )

    result = json.loads(result_str)
    assert result["status"] == "no_targets"
    assert result["total"] == 0
    assert "No rooms found" in result["error"]


# ── fleet_deploy_signal — kill switch ─────────────────────────────


@pytest.mark.asyncio
async def test_fleet_deploy_signal_kill_switch(
    fake_mcp: FakeMCP,
    fake_audit: FakeAudit,
    get_components,
):
    """Kill switch blocks fleet deploy signal."""
    ks = FakeKillSwitch(active=True)
    register_fleet_deploy_tools(fake_mcp, fake_audit, ks, get_components)
    tool = fake_mcp.tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="infrastructure/postgresql",
        confirm=True,
        reason="Should be blocked",
    )

    result = json.loads(result_str)
    assert result.get("kill_switch") is True
    assert "error" in result


# ── fleet_deploy_signal — no confirm ──────────────────────────────


@pytest.mark.asyncio
async def test_fleet_deploy_signal_requires_confirm(registered_tools: dict):
    """fleet_deploy_signal requires confirm=True."""
    tool = registered_tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="infrastructure/postgresql",
        confirm=False,
        reason="No confirmation",
    )

    result = json.loads(result_str)
    assert "error" in result
    assert "confirm" in result["error"].lower() or "confirm" in result.get("hint", "").lower()


# ── fleet_deploy_status ──────────────────────────────────────────


def _make_pool(mock_conn: AsyncMock) -> MagicMock:
    """Build a mock pool whose acquire() is an async context manager."""
    pool = MagicMock()

    @asynccontextmanager
    async def _acquire():
        yield mock_conn

    pool.acquire = _acquire
    pool.close = AsyncMock()
    return pool


@pytest.mark.asyncio
async def test_fleet_deploy_status(registered_tools: dict):
    """Deploy status queries audit log and returns results."""
    tool = registered_tools["fleet_deploy_status"]

    now = datetime(2026, 2, 23, 12, 0, 0)
    mock_conn = AsyncMock()
    mock_conn.fetch = AsyncMock(
        return_value=[
            {
                "project": "my-service",
                "tool": "self_deploy",
                "result_summary": json.dumps({"status": "success"}),
                "timestamp": now,
            },
            {
                "project": "postgresql",
                "tool": "self_update",
                "result_summary": json.dumps({"status": "success"}),
                "timestamp": now,
            },
        ]
    )

    mock_pool = _make_pool(mock_conn)

    with patch("maude.coordination.fleet_deploy.LazyPool") as MockLazyPool:
        lazy = MagicMock()
        lazy.get = AsyncMock(return_value=mock_pool)
        MockLazyPool.return_value = lazy

        result_str = await tool(site="")

    result = json.loads(result_str)
    assert result["total"] == 2
    assert result["deploys"][0]["project"] == "my-service"
    assert result["deploys"][0]["tool"] == "self_deploy"
    assert result["deploys"][0]["status"] == "success"


@pytest.mark.asyncio
async def test_fleet_deploy_status_db_unavailable(registered_tools: dict):
    """Deploy status returns error when DB is unavailable."""
    tool = registered_tools["fleet_deploy_status"]

    with patch("maude.coordination.fleet_deploy.LazyPool") as MockLazyPool:
        lazy = MagicMock()
        lazy.get = AsyncMock(return_value=None)
        MockLazyPool.return_value = lazy

        result_str = await tool(site="")

    result = json.loads(result_str)
    assert "error" in result
    assert result["deploys"] == []


# ── fleet_maude_update ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_maude_update(
    registered_tools: dict,
    graph: DependencyGraph,
    mock_publisher: AsyncMock,
):
    """fleet_maude_update signals self_update to all rooms."""
    tool = registered_tools["fleet_maude_update"]

    result_str = await tool(
        site="",
        confirm=True,
        reason="Library bugfix",
    )

    result = json.loads(result_str)
    assert "action" in result, f"Missing 'action' in: {result}"
    assert result["action"] == "fleet_maude_update"
    assert result["repo"] == MAUDE_REPO
    assert result["status"] == "success"
    assert result["total"] == len(graph.all_rooms)

    # Every signal should have event=True
    for signal in result["signals_sent"]:
        assert signal["event"] is True


@pytest.mark.asyncio
async def test_fleet_maude_update_kill_switch(
    fake_mcp: FakeMCP,
    fake_audit: FakeAudit,
    get_components,
):
    """Kill switch blocks maude update."""
    ks = FakeKillSwitch(active=True)
    register_fleet_deploy_tools(fake_mcp, fake_audit, ks, get_components)
    tool = fake_mcp.tools["fleet_maude_update"]

    result_str = await tool(
        site="",
        confirm=True,
        reason="Should be blocked",
    )

    result = json.loads(result_str)
    assert result.get("kill_switch") is True


@pytest.mark.asyncio
async def test_fleet_maude_update_site_filter(
    registered_tools: dict,
    graph: DependencyGraph,
    mock_publisher: AsyncMock,
):
    """fleet_maude_update with site filter targets only that site."""
    tool = registered_tools["fleet_maude_update"]

    result_str = await tool(
        site="site-b",
        confirm=True,
        reason="PA-only update",
    )

    result = json.loads(result_str)
    assert "status" in result, f"Missing 'status' in: {result}"
    assert result["status"] == "success"
    pa_count = len(graph.rooms_by_site("site-b"))
    assert result["total"] == pa_count
    for signal in result["signals_sent"]:
        assert signal["site"] == "site-b"


# ── Relay failure handling ────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_deploy_signal_relay_failure(
    fake_mcp: FakeMCP,
    fake_audit: FakeAudit,
    fake_kill_switch: FakeKillSwitch,
    get_components,
):
    """Relay failure is non-fatal — event still sent, relay=False."""
    mock_pub = AsyncMock()
    mock_pub.publish = AsyncMock(return_value=True)
    mock_pub.connect = AsyncMock()

    mock_rel = MagicMock()
    mock_rel.send = AsyncMock(side_effect=Exception("PG unavailable"))

    register_fleet_deploy_tools(
        fake_mcp,
        fake_audit,
        fake_kill_switch,
        get_components,
        publisher=mock_pub,
        relay=mock_rel,
    )
    tool = fake_mcp.tools["fleet_deploy_signal"]

    result_str = await tool(
        repo="infrastructure/postgresql",
        site="site-a",
        rooms="",
        confirm=True,
        reason="Testing relay failure",
    )

    result = json.loads(result_str)
    assert result["status"] == "success"
    assert result["signals_sent"][0]["event"] is True
    assert result["signals_sent"][0]["relay"] is False
