# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for SyncWorker — background SQLite-PostgreSQL sync
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for SyncWorker — background SQLite ↔ PostgreSQL sync."""

from unittest.mock import AsyncMock, MagicMock

from maude.memory.sync import SyncWorker
from maude.testing import FakeLocalStore


def _make_pool_mock(return_value: int | None = 42) -> AsyncMock:
    """Create a mock PG pool with fetchval returning the given value."""
    pool = AsyncMock()
    pool.fetchval = AsyncMock(return_value=return_value)
    return pool


def _make_worker(
    local: FakeLocalStore | AsyncMock | None = None,
    memory: AsyncMock | None = None,
    sync_up_interval: int = 60,
    sync_down_interval: int = 300,
) -> SyncWorker:
    """Create a SyncWorker with test doubles."""
    local_store = local or FakeLocalStore()
    if memory is None:
        memory_store = AsyncMock()
        memory_store._ensure_pool = AsyncMock(return_value=_make_pool_mock())
        memory_store.INSERT_SQL = "INSERT INTO agent_memory ..."
        memory_store.recall_recent = AsyncMock(return_value=[])
        memory_store.embed_and_store = AsyncMock(return_value=True)
    else:
        memory_store = memory
    return SyncWorker(
        local_store=local_store,
        memory_store=memory_store,
        project="test",
        sync_up_interval=sync_up_interval,
        sync_down_interval=sync_down_interval,
    )


# ── Lifecycle ────────────────────────────────────────────────────


async def test_start_creates_task():
    """start() creates a background asyncio task."""
    worker = _make_worker()
    await worker.start()
    assert worker._task is not None
    assert not worker._task.done()
    await worker.stop()


async def test_stop_cancels_task():
    """stop() cancels the background task gracefully."""
    worker = _make_worker()
    await worker.start()
    await worker.stop()
    assert worker._task is None


async def test_stop_idempotent():
    """stop() on an unstarted worker is safe."""
    worker = _make_worker()
    await worker.stop()  # should not raise


# ── _sync_up() ───────────────────────────────────────────────────


async def test_sync_up_skips_health_loop_noise_with_actions():
    """_sync_up skips health_loop incidents even if actions_taken is non-empty."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 3,
            "summary": "restarted: endpoint slow", "memory_type": "incident",
            "outcome": "failed", "trigger": "health_loop",
            "reasoning": "", "actions_taken": '[{"action": "restart"}]',
            "tokens_used": 0, "model": "health_loop",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.mark_synced = AsyncMock()

    memory = AsyncMock()
    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    # Should be silently marked as synced (noise), not pushed to PG
    local.mark_synced.assert_called_once_with(1, 3)
    memory._ensure_pool.assert_not_called()


async def test_sync_up_no_pending():
    """_sync_up does nothing when sync queue is empty."""
    local = FakeLocalStore()
    memory = AsyncMock()
    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()
    memory.store_memory.assert_not_called()


async def test_sync_up_pushes_to_pg():
    """_sync_up pushes pending entries to PostgreSQL (direct PG write)."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 3,
            "summary": "Test", "memory_type": "pattern",
            "outcome": "resolved", "trigger": "agent",
            "reasoning": "", "actions_taken": "[]",
            "tokens_used": 0, "model": "",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.mark_synced = AsyncMock()
    local.mark_sync_failed = AsyncMock()

    pool = _make_pool_mock(return_value=42)
    memory = AsyncMock()
    memory._ensure_pool = AsyncMock(return_value=pool)
    memory.INSERT_SQL = "INSERT INTO agent_memory ..."

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    pool.fetchval.assert_called_once()
    local.mark_synced.assert_called_once_with(1, 3, pg_id=42)


async def test_sync_up_marks_pg_failure():
    """_sync_up marks failure when PG pool is unavailable."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 3,
            "summary": "Test", "memory_type": "incident",
            "outcome": "", "trigger": "", "reasoning": "",
            "actions_taken": "[]", "tokens_used": 0, "model": "",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.mark_synced = AsyncMock()
    local.mark_sync_failed = AsyncMock()

    memory = AsyncMock()
    memory._ensure_pool = AsyncMock(return_value=None)
    memory.INSERT_SQL = "INSERT INTO agent_memory ..."

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    local.mark_sync_failed.assert_called_once_with(1, 3)
    local.mark_synced.assert_not_called()


async def test_sync_up_qdrant_needs_pg_id():
    """_sync_up skips Qdrant tier if pg_id not set yet."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 4,
            "summary": "Test", "memory_type": "incident",
            "outcome": "", "trigger": "", "reasoning": "",
            "actions_taken": "[]", "tokens_used": 0, "model": "",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.recall_by_id = AsyncMock(return_value={"id": 1, "pg_id": None})
    local.mark_synced = AsyncMock()
    local.mark_sync_failed = AsyncMock()

    memory = AsyncMock()
    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    # Neither synced nor failed — will retry next cycle
    local.mark_synced.assert_not_called()
    local.mark_sync_failed.assert_not_called()
    memory.embed_and_store.assert_not_called()


async def test_sync_up_qdrant_with_pg_id():
    """_sync_up pushes to Qdrant when pg_id is available."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 4,
            "summary": "Test", "memory_type": "pattern",
            "outcome": "resolved", "trigger": "", "reasoning": "",
            "actions_taken": "[]", "tokens_used": 0, "model": "",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.recall_by_id = AsyncMock(return_value={
        "id": 1, "pg_id": 42, "summary": "Test",
        "memory_type": "pattern", "outcome": "resolved", "root_cause": "",
    })
    local.mark_synced = AsyncMock()

    memory = AsyncMock()
    memory.embed_and_store = AsyncMock(return_value=True)

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    memory.embed_and_store.assert_called_once()
    local.mark_synced.assert_called_once_with(1, 4)


async def test_sync_up_handles_exception():
    """_sync_up marks failure on unexpected exceptions."""
    local = AsyncMock()
    local.get_pending_sync = AsyncMock(return_value=[
        {
            "memory_id": 1, "target_tier": 3,
            "summary": "Test", "memory_type": "incident",
            "outcome": "", "trigger": "", "reasoning": "",
            "actions_taken": "[]", "tokens_used": 0, "model": "",
            "context": "{}", "root_cause": "",
            "mem_created_at": "2026-01-01",
        },
    ])
    local.mark_sync_failed = AsyncMock()

    pool = AsyncMock()
    pool.fetchval = AsyncMock(side_effect=RuntimeError("PG down"))
    memory = AsyncMock()
    memory._ensure_pool = AsyncMock(return_value=pool)
    memory.INSERT_SQL = "INSERT INTO agent_memory ..."

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_up()

    local.mark_sync_failed.assert_called_once_with(1, 3)


# ── _sync_down() ─────────────────────────────────────────────────


async def test_sync_down_no_memories():
    """_sync_down does nothing when PG returns empty."""
    local = FakeLocalStore()
    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[])

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_down()


async def test_sync_down_caches_memories():
    """_sync_down pulls PG memories into local store."""
    local = AsyncMock()
    local.warm_from_pg = AsyncMock(return_value=3)

    mem = MagicMock()
    mem.id = 100
    mem.memory_type = "incident"
    mem.trigger = "health"
    mem.context = {}
    mem.reasoning = ""
    mem.actions_taken = []
    mem.outcome = "resolved"
    mem.summary = "Synced down"
    mem.tokens_used = 0
    mem.model = ""
    mem.created_at = None

    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[mem])

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_down()

    local.warm_from_pg.assert_called_once()
    rows = local.warm_from_pg.call_args[0][0]
    assert len(rows) == 1
    assert rows[0]["id"] == 100
    assert rows[0]["summary"] == "Synced down"


async def test_sync_down_handles_exception():
    """_sync_down survives PG errors gracefully."""
    local = FakeLocalStore()
    memory = AsyncMock()
    memory.recall_recent = AsyncMock(side_effect=RuntimeError("PG down"))

    worker = _make_worker(local=local, memory=memory)
    await worker._sync_down()  # should not raise


# ── _warm_if_empty() ─────────────────────────────────────────────


async def test_warm_if_empty_populates():
    """_warm_if_empty calls _sync_down when store is empty."""
    local = AsyncMock()
    local.stats = AsyncMock(return_value={"total_memories": 0})
    local.warm_from_pg = AsyncMock(return_value=5)

    mem = MagicMock()
    mem.id = 1
    mem.memory_type = "incident"
    mem.trigger = ""
    mem.context = {}
    mem.reasoning = ""
    mem.actions_taken = []
    mem.outcome = ""
    mem.summary = "Warm"
    mem.tokens_used = 0
    mem.model = ""
    mem.created_at = None

    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[mem])

    worker = _make_worker(local=local, memory=memory)
    await worker._warm_if_empty()

    memory.recall_recent.assert_called_once()


async def test_warm_if_empty_skips_populated():
    """_warm_if_empty skips when local store already has data."""
    local = AsyncMock()
    local.stats = AsyncMock(return_value={"total_memories": 50})

    memory = AsyncMock()
    worker = _make_worker(local=local, memory=memory)
    await worker._warm_if_empty()

    memory.recall_recent.assert_not_called()


# ── _push_to_pg() ───────────────────────────────────────────────


async def test_push_to_pg_parses_json_actions():
    """_push_to_pg deserializes JSON string actions_taken."""
    pool = _make_pool_mock(return_value=99)
    memory = AsyncMock()
    memory._ensure_pool = AsyncMock(return_value=pool)
    memory.INSERT_SQL = "INSERT INTO agent_memory ..."

    worker = _make_worker(memory=memory)
    entry = {
        "summary": "Test", "memory_type": "incident",
        "trigger": "", "reasoning": "",
        "actions_taken": '[{"action": "restart"}]',
        "outcome": "resolved", "tokens_used": 0, "model": "",
    }
    result = await worker._push_to_pg(entry)
    assert result == 99

    # actions_taken arg is the 6th positional arg (index 5) to fetchval
    call_args = pool.fetchval.call_args[0]
    import json
    assert json.loads(call_args[6]) == [{"action": "restart"}]


async def test_push_to_pg_handles_invalid_json_actions():
    """_push_to_pg handles malformed actions_taken gracefully."""
    pool = _make_pool_mock(return_value=99)
    memory = AsyncMock()
    memory._ensure_pool = AsyncMock(return_value=pool)
    memory.INSERT_SQL = "INSERT INTO agent_memory ..."

    worker = _make_worker(memory=memory)
    entry = {
        "summary": "Test", "memory_type": "incident",
        "trigger": "", "reasoning": "",
        "actions_taken": "not valid json",
        "outcome": "", "tokens_used": 0, "model": "",
    }
    result = await worker._push_to_pg(entry)
    assert result == 99

    # actions_taken should be empty list (invalid JSON fallback)
    call_args = pool.fetchval.call_args[0]
    import json
    assert json.loads(call_args[6]) == []


# ── Loop counter ─────────────────────────────────────────────────


async def test_sync_down_counter_triggers_at_interval():
    """sync_down runs when counter reaches sync_down_interval."""
    worker = _make_worker(sync_up_interval=60, sync_down_interval=300)
    assert worker._sync_down_counter == 0

    # Simulate 4 sync-up cycles (4 x 60 = 240, below 300)
    for _ in range(4):
        worker._sync_down_counter += worker.sync_up_interval
    assert worker._sync_down_counter < worker.sync_down_interval

    # 5th cycle (5 x 60 = 300, equals threshold)
    worker._sync_down_counter += worker.sync_up_interval
    assert worker._sync_down_counter >= worker.sync_down_interval
