# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for Relay — structured inter-room relay with task state machine.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for Relay — structured inter-room relay with task state machine."""

from contextlib import asynccontextmanager
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.coordination.relay import (
    VALID_TRANSITIONS,
    Relay,
    RelayTask,
    TaskStatus,
    _row_to_task,
)


def _make_pool(mock_conn: AsyncMock) -> MagicMock:
    """Build a mock pool whose acquire() is an async context manager."""
    pool = MagicMock()

    @asynccontextmanager
    async def _acquire():
        yield mock_conn

    pool.acquire = _acquire
    pool.close = AsyncMock()
    return pool


def _make_row(**overrides: object) -> dict:
    """Build a mock relay_tasks row dict."""
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


def _fake_transaction():
    """Return a no-op async context manager matching asyncpg transaction()."""

    @asynccontextmanager
    async def _txn():
        yield

    return _txn()


@pytest.fixture
def mock_conn() -> AsyncMock:
    conn = AsyncMock()
    # Default: NOTIFY succeeds
    conn.execute = AsyncMock()
    # transaction() returns a sync object that is an async context manager
    conn.transaction = _fake_transaction
    return conn


@pytest.fixture
def mock_pool(mock_conn: AsyncMock) -> MagicMock:
    return _make_pool(mock_conn)


@pytest.fixture
def relay(mock_pool: MagicMock) -> Relay:
    return Relay(pool=mock_pool)


# ── Construction ──────────────────────────────────────────────────


def test_init_with_pool(relay, mock_pool):
    assert relay._db._pool is mock_pool
    assert relay._owns_pool is False


def test_init_without_pool():
    r = Relay()
    assert r._db._pool is None
    assert r._owns_pool is True


# ── TaskStatus enum ──────────────────────────────────────────────


def test_task_status_values():
    assert TaskStatus.PENDING == "pending"
    assert TaskStatus.COMPLETED == "completed"
    assert TaskStatus.FAILED == "failed"
    assert TaskStatus.CANCELLED == "cancelled"


def test_valid_transitions():
    """Verify the state machine transitions."""
    assert TaskStatus.ACCEPTED in VALID_TRANSITIONS[TaskStatus.PENDING]
    assert TaskStatus.CANCELLED in VALID_TRANSITIONS[TaskStatus.PENDING]
    assert TaskStatus.RUNNING in VALID_TRANSITIONS[TaskStatus.ACCEPTED]
    assert TaskStatus.COMPLETED in VALID_TRANSITIONS[TaskStatus.RUNNING]
    assert TaskStatus.FAILED in VALID_TRANSITIONS[TaskStatus.RUNNING]
    # No transitions out of terminal states
    assert TaskStatus.COMPLETED not in VALID_TRANSITIONS
    assert TaskStatus.FAILED not in VALID_TRANSITIONS


# ── send() ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_send_creates_task(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value={"id": 42})

    task_id = await relay.send("my-service", "monitoring", "Panel stale", "Dashboard refresh")

    assert task_id == 42
    mock_conn.fetchrow.assert_awaited_once()
    call_args = mock_conn.fetchrow.call_args
    assert call_args[0][1] == "my-service"  # from_room
    assert call_args[0][2] == "monitoring"  # to_room
    assert call_args[0][3] == "Panel stale"  # subject


@pytest.mark.asyncio
async def test_send_with_priority(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value={"id": 43})

    task_id = await relay.send("my-service", "monitoring", "Urgent", "Fix now", priority=5)

    assert task_id == 43
    call_args = mock_conn.fetchrow.call_args
    assert call_args[0][5] == 5  # priority parameter


@pytest.mark.asyncio
async def test_send_publishes_notify(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value={"id": 44})

    await relay.send("my-service", "monitoring", "Test", "Body")

    # Should call execute for pg_notify
    mock_conn.execute.assert_awaited()
    notify_call = mock_conn.execute.call_args
    assert "pg_notify" in notify_call[0][0]


# ── accept() ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_accept_transitions_pending_to_accepted(relay, mock_conn):
    pending_row = _make_row(status="pending")
    accepted_row = _make_row(status="accepted")
    mock_conn.fetchrow = AsyncMock(side_effect=[pending_row, accepted_row])

    task = await relay.accept(1, "monitoring")

    assert task.status == TaskStatus.ACCEPTED


@pytest.mark.asyncio
async def test_accept_rejects_wrong_room(relay, mock_conn):
    pending_row = _make_row(status="pending", to_room="monitoring")
    mock_conn.fetchrow = AsyncMock(return_value=pending_row)

    with pytest.raises(ValueError, match="cannot update"):
        await relay.accept(1, "my-service")


@pytest.mark.asyncio
async def test_accept_rejects_invalid_transition(relay, mock_conn):
    completed_row = _make_row(status="completed")
    mock_conn.fetchrow = AsyncMock(return_value=completed_row)

    with pytest.raises(ValueError, match="Invalid transition"):
        await relay.accept(1, "monitoring")


# ── update() ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_update_to_completed(relay, mock_conn):
    running_row = _make_row(status="running")
    completed_row = _make_row(status="completed", result="Done")
    mock_conn.fetchrow = AsyncMock(side_effect=[running_row, completed_row])

    task = await relay.update(1, "monitoring", "completed", result="Done")

    assert task.status == TaskStatus.COMPLETED


@pytest.mark.asyncio
async def test_update_to_failed(relay, mock_conn):
    running_row = _make_row(status="running")
    failed_row = _make_row(status="failed", result="Timeout")
    mock_conn.fetchrow = AsyncMock(side_effect=[running_row, failed_row])

    task = await relay.update(1, "monitoring", "failed", result="Timeout")

    assert task.status == TaskStatus.FAILED


@pytest.mark.asyncio
async def test_update_cancelled_from_pending(relay, mock_conn):
    pending_row = _make_row(status="pending")
    cancelled_row = _make_row(status="cancelled")
    mock_conn.fetchrow = AsyncMock(side_effect=[pending_row, cancelled_row])

    task = await relay.update(1, "monitoring", "cancelled")

    assert task.status == TaskStatus.CANCELLED


@pytest.mark.asyncio
async def test_update_not_found(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value=None)

    with pytest.raises(ValueError, match="not found"):
        await relay.update(999, "monitoring", "completed")


# ── get() ─────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_returns_task(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value=_make_row(id=5))

    task = await relay.get(5)

    assert task is not None
    assert task.id == 5
    assert task.from_room == "my-service"


@pytest.mark.asyncio
async def test_get_not_found(relay, mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value=None)

    task = await relay.get(999)
    assert task is None


# ── tasks() ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_tasks_returns_list(relay, mock_conn):
    mock_conn.fetch = AsyncMock(
        return_value=[
            _make_row(id=1),
            _make_row(id=2),
        ]
    )

    result = await relay.tasks(room="monitoring", limit=10)

    assert len(result) == 2
    assert result[0].id == 1
    assert result[1].id == 2


@pytest.mark.asyncio
async def test_tasks_with_filters(relay, mock_conn):
    mock_conn.fetch = AsyncMock(return_value=[])

    await relay.tasks(room="monitoring", status="pending", from_room="my-service", since_minutes=30)

    call_args = mock_conn.fetch.call_args
    sql = call_args[0][0]
    assert "to_room" in sql
    assert "status" in sql
    assert "from_room" in sql
    assert "make_interval" in sql


# ── inbox() backward compat ──────────────────────────────────────


@pytest.mark.asyncio
async def test_inbox_returns_legacy_format(relay, mock_conn):
    mock_conn.fetch = AsyncMock(return_value=[_make_row(id=1)])

    messages = await relay.inbox("monitoring", limit=10, since_minutes=30)

    assert len(messages) == 1
    msg = messages[0]
    assert msg["id"] == 1
    assert msg["body"] == "Test body"
    assert msg["from_room"] == "my-service"
    assert msg["subject"] == "Test"
    assert "ts" in msg
    assert "status" in msg


# ── sweep_stale() ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_sweep_stale_marks_failed(relay, mock_conn):
    mock_conn.fetch = AsyncMock(return_value=[{"id": 10}, {"id": 11}])

    ids = await relay.sweep_stale()

    assert ids == [10, 11]


@pytest.mark.asyncio
async def test_sweep_stale_no_stale(relay, mock_conn):
    mock_conn.fetch = AsyncMock(return_value=[])

    ids = await relay.sweep_stale()
    assert ids == []


# ── RelayTask.to_dict() ─────────────────────────────────────────


def test_relay_task_to_dict():
    now = datetime(2026, 3, 14, 12, 0, 0, tzinfo=timezone.utc)
    task = RelayTask(
        id=1,
        from_room="a",
        to_room="b",
        subject="s",
        body="body",
        status=TaskStatus.PENDING,
        result=None,
        priority=0,
        created_at=now,
        updated_at=now,
        accepted_at=None,
        completed_at=None,
    )
    d = task.to_dict()
    assert d["id"] == 1
    assert d["status"] == "pending"
    assert d["accepted_at"] is None
    assert "2026" in d["created_at"]


# ── _row_to_task() ───────────────────────────────────────────────


def test_row_to_task():
    row = _make_row(id=7, status="running")
    task = _row_to_task(row)
    assert task.id == 7
    assert task.status == TaskStatus.RUNNING


# ── close() ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_owned_pool():
    pool = AsyncMock()
    r = Relay()
    r._db._pool = pool
    r._owns_pool = True
    await r.close()
    pool.close.assert_awaited_once()
    assert r._db._pool is None


@pytest.mark.asyncio
async def test_close_borrowed_pool(relay, mock_pool):
    """Should NOT close a pool it didn't create."""
    await relay.close()
    mock_pool.close.assert_not_awaited()
