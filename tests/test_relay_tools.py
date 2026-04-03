# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for maude.relay_tools — per-room A2A relay tools.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for maude.relay_tools — per-room A2A relay tools.

Verifies identity scoping: rooms can only send as themselves and
accept/update tasks addressed to themselves.
"""

import json
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.daemon.relay_tools import register_relay_tools
from maude.testing import FakeAudit, FakeMCP, reset_rate_limits


@pytest.fixture(autouse=True)
def _reset():
    reset_rate_limits()


def _make_row(**overrides):
    now = datetime(2026, 3, 14, 12, 0, 0, tzinfo=timezone.utc)
    defaults = {
        "id": 1,
        "from_room": "my-service",
        "to_room": "monitoring",
        "subject": "Test",
        "body": "Test body",
        "status": "pending",
        "result": None,
        "priority": 0,
        "created_at": now,
        "updated_at": now,
        "accepted_at": None,
        "completed_at": None,
    }
    defaults.update(overrides)
    return defaults


def _make_pool(mock_conn):
    pool = MagicMock()

    @asynccontextmanager
    async def _acquire():
        yield mock_conn

    pool.acquire = _acquire
    pool.close = AsyncMock()
    return pool


@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    conn.execute = AsyncMock()

    @asynccontextmanager
    async def _txn():
        yield

    conn.transaction = _txn
    return conn


@pytest.fixture
def mock_pool(mock_conn):
    return _make_pool(mock_conn)


@pytest.fixture
def tools(mock_pool):
    """Register relay tools for 'my-service' room with a mock pool."""
    mcp = FakeMCP()
    audit = FakeAudit()

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance

        register_relay_tools(mcp, audit, "my-service")

    return mcp.tools


# ── Registration ─────────────────────────────────────────────────


def test_registers_5_tools(tools):
    """register_relay_tools registers exactly 5 tools."""
    assert len(tools) == 5


def test_tool_names(tools):
    """All 5 expected tool names are registered."""
    assert "relay_send" in tools
    assert "relay_accept" in tools
    assert "relay_update" in tools
    assert "relay_inbox" in tools
    assert "relay_accept_incoming" in tools


# ── Identity scoping ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_send_uses_own_identity(mock_pool, mock_conn):
    """relay_send hardcodes from_room to the room's project name."""
    mcp = FakeMCP()
    audit = FakeAudit()

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance
        mock_conn.fetchrow = AsyncMock(return_value={"id": 42})

        register_relay_tools(mcp, audit, "my-service")

    result = json.loads(
        await mcp.tools["relay_send"](
            to_room="monitoring",
            subject="Help",
            body="Panel stale",
        )
    )

    assert result["from_room"] == "my-service"
    assert result["to_room"] == "monitoring"
    assert result["task_id"] == 42


@pytest.mark.asyncio
async def test_accept_uses_own_identity(mock_pool, mock_conn):
    """relay_accept passes this room's project as the accepting room."""
    mcp = FakeMCP()
    audit = FakeAudit()

    pending = _make_row(status="pending", to_room="my-service")
    accepted = _make_row(status="accepted", to_room="my-service")
    mock_conn.fetchrow = AsyncMock(side_effect=[pending, accepted])

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance

        register_relay_tools(mcp, audit, "my-service")

    result = json.loads(await mcp.tools["relay_accept"](task_id=1))

    assert result["status"] == "accepted"


@pytest.mark.asyncio
async def test_accept_rejects_other_rooms_task(mock_pool, mock_conn):
    """relay_accept fails when task is addressed to a different room."""
    mcp = FakeMCP()
    audit = FakeAudit()

    # Task is addressed to monitoring, not my-service
    pending = _make_row(status="pending", to_room="monitoring")
    mock_conn.fetchrow = AsyncMock(return_value=pending)

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance

        register_relay_tools(mcp, audit, "my-service")

    result = json.loads(await mcp.tools["relay_accept"](task_id=1))

    assert "error" in result
    assert "cannot update" in result["error"]


# ── Inbox scoping ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_inbox_scoped_to_own_room(mock_pool, mock_conn):
    """relay_inbox queries only tasks addressed to this room."""
    mcp = FakeMCP()
    audit = FakeAudit()
    mock_conn.fetch = AsyncMock(return_value=[])

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance

        register_relay_tools(mcp, audit, "my-service")

    await mcp.tools["relay_inbox"]()

    # Verify the SQL query filters by room=my-service
    call_args = mock_conn.fetch.call_args
    sql = call_args[0][0]
    assert "to_room" in sql
    # First param should be "my-service"
    assert call_args[0][1] == "my-service"
