# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for maude.daemon.relay_buffer — local outbox + background drain.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for RelayOutbox and RelayOutboxWorker.

Covers:
- Outbox SQLite CRUD (enqueue, pending, mark_synced, mark_failed, increment)
- Worker drain loop (PG success, P2P fallback, both-fail retry)
- Attempt limit exhaustion → failed status
- relay_send buffer fallback in relay_tools
"""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.daemon.relay_buffer import (
    MAX_ATTEMPTS,
    RelayOutbox,
    RelayOutboxWorker,
)
from maude.testing import FakeRelayOutbox, reset_rate_limits

# ── Fixtures ──────────────────────────────────────────────────────


@pytest.fixture
def fake_local_store(tmp_path):
    """Real LocalStore with a temp database for outbox CRUD tests."""
    from maude.memory.local_store import LocalStore

    return LocalStore(project="test-room", db_path=tmp_path / "memory.db")


@pytest.fixture
def outbox(fake_local_store):
    return RelayOutbox(fake_local_store, "test-room")


@pytest.fixture
def fake_outbox():
    return FakeRelayOutbox()


@pytest.fixture
def fake_relay():
    """Mock Relay with controllable send_lenient."""
    relay = MagicMock()
    relay.send_lenient = AsyncMock(return_value=None)  # PG down by default
    return relay


@pytest.fixture
def fake_dep_graph():
    """Mock DependencyGraph with room info."""
    graph = MagicMock()
    graph.room_info.return_value = {
        "ip": "localhost",
        "mcp_port": 9500,
    }
    return graph


@pytest.fixture(autouse=True)
def _reset():
    reset_rate_limits()


# ── RelayOutbox CRUD ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_enqueue_returns_id(outbox):
    local_id = await outbox.enqueue("monitoring", "Test", "Body")
    assert local_id == 1


@pytest.mark.asyncio
async def test_enqueue_multiple(outbox):
    id1 = await outbox.enqueue("monitoring", "First", "Body 1")
    id2 = await outbox.enqueue("my-service", "Second", "Body 2")
    assert id1 != id2


@pytest.mark.asyncio
async def test_pending_returns_unsynced(outbox):
    await outbox.enqueue("monitoring", "Test", "Body")
    entries = await outbox.pending()
    assert len(entries) == 1
    assert entries[0]["to_room"] == "monitoring"
    assert entries[0]["status"] == "pending"


@pytest.mark.asyncio
async def test_pending_excludes_synced(outbox):
    oid = await outbox.enqueue("monitoring", "Test", "Body")
    await outbox.mark_synced(oid, pg_task_id=42)
    entries = await outbox.pending()
    assert len(entries) == 0


@pytest.mark.asyncio
async def test_pending_excludes_failed(outbox):
    oid = await outbox.enqueue("monitoring", "Test", "Body")
    await outbox.mark_failed(oid)
    entries = await outbox.pending()
    assert len(entries) == 0


@pytest.mark.asyncio
async def test_mark_synced_sets_pg_task_id(outbox):
    oid = await outbox.enqueue("monitoring", "Test", "Body")
    await outbox.mark_synced(oid, pg_task_id=99)
    # Verify by checking stats
    stats = await outbox.stats()
    assert stats["synced"] == 1
    assert stats["pending"] == 0


@pytest.mark.asyncio
async def test_increment_attempt(outbox):
    oid = await outbox.enqueue("monitoring", "Test", "Body")
    await outbox.increment_attempt(oid)
    entries = await outbox.pending()
    assert len(entries) == 1
    assert entries[0]["attempts"] == 1


@pytest.mark.asyncio
async def test_increment_to_max_marks_failed(outbox):
    oid = await outbox.enqueue("monitoring", "Test", "Body")
    for _ in range(MAX_ATTEMPTS):
        await outbox.increment_attempt(oid)
    entries = await outbox.pending()
    assert len(entries) == 0
    stats = await outbox.stats()
    assert stats["failed"] == 1


@pytest.mark.asyncio
async def test_pending_respects_limit(outbox):
    for i in range(5):
        await outbox.enqueue("monitoring", f"Test {i}", "Body")
    entries = await outbox.pending(limit=3)
    assert len(entries) == 3


@pytest.mark.asyncio
async def test_stats(outbox):
    await outbox.enqueue("monitoring", "Pending", "Body")
    oid2 = await outbox.enqueue("my-service", "Synced", "Body")
    await outbox.mark_synced(oid2)
    oid3 = await outbox.enqueue("loki", "Failed", "Body")
    await outbox.mark_failed(oid3)

    stats = await outbox.stats()
    assert stats["pending"] == 1
    assert stats["synced"] == 1
    assert stats["failed"] == 1


# ── FakeRelayOutbox ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fake_outbox_enqueue():
    fake = FakeRelayOutbox()
    oid = await fake.enqueue("monitoring", "Test", "Body")
    assert oid == 1
    entries = await fake.pending()
    assert len(entries) == 1


@pytest.mark.asyncio
async def test_fake_outbox_mark_synced():
    fake = FakeRelayOutbox()
    oid = await fake.enqueue("monitoring", "Test", "Body")
    await fake.mark_synced(oid, pg_task_id=42)
    entries = await fake.pending()
    assert len(entries) == 0


@pytest.mark.asyncio
async def test_fake_outbox_increment_to_failed():
    fake = FakeRelayOutbox()
    oid = await fake.enqueue("monitoring", "Test", "Body")
    for _ in range(10):
        await fake.increment_attempt(oid)
    entries = await fake.pending()
    assert len(entries) == 0
    stats = await fake.stats()
    assert stats["failed"] == 1


# ── RelayOutboxWorker drain ───────────────────────────────────────


@pytest.mark.asyncio
async def test_drain_pg_success(fake_outbox, fake_relay):
    """When PG is available, drain syncs to PG and marks synced."""
    fake_relay.send_lenient = AsyncMock(return_value=42)
    worker = RelayOutboxWorker(fake_outbox, fake_relay, "test-room")

    await fake_outbox.enqueue("monitoring", "Test", "Body")
    await worker._drain()

    entries = await fake_outbox.pending()
    assert len(entries) == 0
    stats = await fake_outbox.stats()
    assert stats["synced"] == 1


@pytest.mark.asyncio
async def test_drain_pg_fail_p2p_success(fake_outbox, fake_relay, fake_dep_graph):
    """When PG fails, falls back to P2P HTTP and marks synced."""
    fake_relay.send_lenient = AsyncMock(return_value=None)
    worker = RelayOutboxWorker(
        fake_outbox,
        fake_relay,
        "test-room",
        dep_graph=fake_dep_graph,
    )

    await fake_outbox.enqueue("monitoring", "Test", "Body")

    # Mock httpx to succeed
    mock_resp = MagicMock()
    mock_resp.status_code = 200

    mock_client = AsyncMock()
    mock_client.post = AsyncMock(return_value=mock_resp)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("maude.daemon.relay_buffer.httpx", create=True) as mock_httpx:
        mock_httpx.AsyncClient.return_value = mock_client
        with patch.dict("sys.modules", {"httpx": mock_httpx}):
            await worker._drain()

    stats = await fake_outbox.stats()
    assert stats["synced"] == 1


@pytest.mark.asyncio
async def test_drain_both_fail_increments_attempt(fake_outbox, fake_relay):
    """When both PG and P2P fail, increments attempt counter."""
    fake_relay.send_lenient = AsyncMock(return_value=None)
    worker = RelayOutboxWorker(
        fake_outbox,
        fake_relay,
        "test-room",
        dep_graph=None,  # no P2P
    )

    await fake_outbox.enqueue("monitoring", "Test", "Body")
    await worker._drain()

    entries = await fake_outbox.pending()
    assert len(entries) == 1
    assert entries[0]["attempts"] == 1


@pytest.mark.asyncio
async def test_drain_exhausted_attempts(fake_outbox, fake_relay):
    """After MAX_ATTEMPTS, entry is marked failed."""
    fake_relay.send_lenient = AsyncMock(return_value=None)
    worker = RelayOutboxWorker(
        fake_outbox,
        fake_relay,
        "test-room",
        dep_graph=None,
    )

    await fake_outbox.enqueue("monitoring", "Test", "Body")

    for _ in range(MAX_ATTEMPTS):
        await worker._drain()

    entries = await fake_outbox.pending()
    assert len(entries) == 0
    stats = await fake_outbox.stats()
    assert stats["failed"] == 1


@pytest.mark.asyncio
async def test_drain_empty_is_noop(fake_outbox, fake_relay):
    """Drain with no pending entries does nothing."""
    worker = RelayOutboxWorker(fake_outbox, fake_relay, "test-room")
    await worker._drain()  # should not raise


@pytest.mark.asyncio
async def test_drain_multiple_entries(fake_outbox, fake_relay):
    """Drains all pending entries in one pass."""
    fake_relay.send_lenient = AsyncMock(return_value=42)
    worker = RelayOutboxWorker(fake_outbox, fake_relay, "test-room")

    await fake_outbox.enqueue("monitoring", "Test 1", "Body 1")
    await fake_outbox.enqueue("my-service", "Test 2", "Body 2")
    await fake_outbox.enqueue("loki", "Test 3", "Body 3")

    await worker._drain()

    stats = await fake_outbox.stats()
    assert stats["synced"] == 3
    assert stats["pending"] == 0


# ── P2P fallback detail ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_p2p_no_dep_graph():
    """Without a DependencyGraph, P2P returns False."""
    fake_outbox = FakeRelayOutbox()
    fake_relay = MagicMock()
    worker = RelayOutboxWorker(fake_outbox, fake_relay, "test-room", dep_graph=None)
    result = await worker._try_p2p("monitoring", "Test", "Body")
    assert result is False


@pytest.mark.asyncio
async def test_p2p_no_room_info(fake_dep_graph):
    """If room has no ip/port, P2P returns False."""
    fake_dep_graph.room_info.return_value = {}  # no ip/port
    fake_outbox = FakeRelayOutbox()
    fake_relay = MagicMock()
    worker = RelayOutboxWorker(
        fake_outbox,
        fake_relay,
        "test-room",
        dep_graph=fake_dep_graph,
    )
    result = await worker._try_p2p("monitoring", "Test", "Body")
    assert result is False


# ── Worker start/stop ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_worker_start_stop(fake_outbox, fake_relay):
    """Worker starts and stops cleanly."""
    worker = RelayOutboxWorker(
        fake_outbox,
        fake_relay,
        "test-room",
        interval=1,
    )
    await worker.start()
    assert worker._task is not None
    await worker.stop()
    assert worker._task is None


# ── relay_send buffer fallback ────────────────────────────────────


@pytest.mark.asyncio
async def test_relay_send_buffers_on_pg_failure():
    """relay_send falls back to local outbox when PG is unavailable."""
    from maude.daemon.relay_tools import register_relay_tools
    from maude.testing import FakeAudit, FakeMCP

    mcp = FakeMCP()
    audit = FakeAudit()

    # Use a FakeLocalStore that has the outbox table behavior
    fake_store = MagicMock()
    fake_store._get_conn = MagicMock()
    fake_store.initialize = AsyncMock()

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance.get = AsyncMock(return_value=None)  # PG unavailable
        instance._pool = None
        MockPR.get.return_value = instance

        with patch("maude.daemon.relay_buffer.RelayOutbox") as MockOutbox:
            mock_outbox = MockOutbox.return_value
            mock_outbox.enqueue = AsyncMock(return_value=99)

            register_relay_tools(mcp, audit, "my-service", local_store=fake_store)

    result = json.loads(
        await mcp.tools["relay_send"](
            to_room="monitoring",
            subject="Help",
            body="Panel stale",
        )
    )

    assert result["delivery"] == "buffered"
    assert result["local_id"] == 99
    assert result["from_room"] == "my-service"


@pytest.mark.asyncio
async def test_relay_send_direct_when_pg_up():
    """relay_send delivers directly to PG when available."""
    from contextlib import asynccontextmanager

    from maude.daemon.relay_tools import register_relay_tools
    from maude.testing import FakeAudit, FakeMCP

    mcp = FakeMCP()
    audit = FakeAudit()

    mock_conn = AsyncMock()
    mock_conn.fetchrow = AsyncMock(return_value={"id": 42})
    mock_conn.execute = AsyncMock()

    @asynccontextmanager
    async def _txn():
        yield

    mock_conn.transaction = _txn

    mock_pool = MagicMock()

    @asynccontextmanager
    async def _acquire():
        yield mock_conn

    mock_pool.acquire = _acquire

    with patch("maude.coordination.relay.PoolRegistry") as MockPR:
        instance = MagicMock()
        instance._pool = mock_pool
        instance.get = AsyncMock(return_value=mock_pool)
        MockPR.get.return_value = instance

        register_relay_tools(mcp, audit, "my-service", local_store=MagicMock())

    result = json.loads(
        await mcp.tools["relay_send"](
            to_room="monitoring",
            subject="Help",
            body="Panel stale",
        )
    )

    assert result["delivery"] == "direct"
    assert result["task_id"] == 42


# ── relay_accept_incoming ────────────────────────────────────────


@pytest.mark.asyncio
async def test_relay_accept_incoming_stores_locally():
    """P2P relay receive stores as a local memory entry."""
    from maude.daemon.relay_tools import register_relay_tools
    from maude.testing import FakeAudit, FakeMCP

    mcp = FakeMCP()
    audit = FakeAudit()

    fake_store = AsyncMock()
    fake_store.store = AsyncMock(return_value=1)
    fake_store.initialize = AsyncMock()

    with patch("maude.coordination.relay.LazyPool") as MockLP:
        instance = MockLP.return_value
        instance.get = AsyncMock(return_value=None)
        instance._pool = None

        register_relay_tools(mcp, audit, "my-service", local_store=fake_store)

    result = json.loads(
        await mcp.tools["relay_accept_incoming"](
            from_room="monitoring",
            subject="Alert",
            body="CPU high",
        )
    )

    assert result["accepted"] is True
    assert result["delivery"] == "p2p"
    assert result["from_room"] == "monitoring"
    assert result["to_room"] == "my-service"

    # Verify local store was called
    fake_store.store.assert_awaited_once()
    call_kwargs = fake_store.store.call_args
    assert call_kwargs[1]["memory_type"] == "relay_incoming"
    assert "monitoring" in call_kwargs[1]["summary"]


@pytest.mark.asyncio
async def test_relay_accept_incoming_no_store():
    """P2P relay receive fails gracefully without local store."""
    from maude.daemon.relay_tools import register_relay_tools
    from maude.testing import FakeAudit, FakeMCP

    mcp = FakeMCP()
    audit = FakeAudit()

    with patch("maude.coordination.relay.LazyPool") as MockLP:
        instance = MockLP.return_value
        instance.get = AsyncMock(return_value=None)
        instance._pool = None

        register_relay_tools(mcp, audit, "my-service")  # no local_store

    result = json.loads(
        await mcp.tools["relay_accept_incoming"](
            from_room="monitoring",
            subject="Alert",
            body="CPU high",
        )
    )

    assert result["accepted"] is False
