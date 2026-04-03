# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for LocalStore — SQLite-backed sovereign memory
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for LocalStore — SQLite-backed sovereign memory."""

import json
from pathlib import Path

import pytest

from maude.memory.local_store import LocalStore


@pytest.fixture
async def store(tmp_path: Path) -> LocalStore:
    """Create a LocalStore backed by a temp SQLite database."""
    s = LocalStore(project="test", db_path=tmp_path / "memory.db")
    await s.initialize()
    return s


# ── Initialization ───────────────────────────────────────────────


async def test_initialize_creates_db(tmp_path: Path):
    """Database file is created on initialize."""
    db_path = tmp_path / "memory.db"
    store = LocalStore(project="test", db_path=db_path)
    await store.initialize()
    assert db_path.exists()
    await store.close()


async def test_initialize_idempotent(store: LocalStore):
    """Calling initialize() twice is safe."""
    await store.initialize()
    await store.initialize()
    stats = await store.stats()
    assert stats["total_memories"] == 0


async def test_wal_mode(tmp_path: Path):
    """SQLite is configured in WAL mode."""
    import sqlite3

    db_path = tmp_path / "wal_test.db"
    store = LocalStore(project="test", db_path=db_path)
    await store.initialize()
    conn = sqlite3.connect(str(db_path))
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    conn.close()
    assert mode == "wal"
    await store.close()


# ── store() ──────────────────────────────────────────────────────


async def test_store_returns_id(store: LocalStore):
    """store() returns a positive integer ID."""
    local_id = await store.store(
        memory_type="incident",
        summary="Service restarted",
        trigger="health_loop",
        outcome="resolved",
    )
    assert local_id > 0


async def test_store_increments_id(store: LocalStore):
    """Sequential stores produce incrementing IDs."""
    id1 = await store.store(memory_type="incident", summary="First")
    id2 = await store.store(memory_type="incident", summary="Second")
    assert id2 > id1


async def test_store_enqueues_sync(store: LocalStore):
    """tier_origin=1 records are queued for PG and Qdrant sync."""
    await store.store(memory_type="incident", summary="Test")
    pending = await store.get_pending_sync()
    assert len(pending) == 2  # PG (tier 3) + Qdrant (tier 4)
    tiers = {e["target_tier"] for e in pending}
    assert tiers == {3, 4}


async def test_store_no_sync_when_disabled(store: LocalStore):
    """enqueue_sync=False skips the sync queue."""
    await store.store(
        memory_type="incident",
        summary="Test",
        enqueue_sync=False,
    )
    pending = await store.get_pending_sync()
    assert len(pending) == 0


async def test_store_no_sync_for_pg_origin(store: LocalStore):
    """tier_origin=3 (PG sync-down) records are NOT queued for sync-up."""
    await store.store(
        memory_type="incident",
        summary="From PG",
        tier_origin=3,
    )
    pending = await store.get_pending_sync()
    assert len(pending) == 0


async def test_store_context_serialized(store: LocalStore):
    """Context dict is stored as JSON string."""
    await store.store(
        memory_type="incident",
        summary="Test",
        context={"service": "monitoring", "port": 8080},
    )
    rows = await store.recall_recent()
    assert json.loads(rows[0]["context"]) == {"service": "monitoring", "port": 8080}


async def test_store_actions_serialized(store: LocalStore):
    """Actions list is stored as JSON string."""
    actions = [{"action": "restart", "result": "ok"}]
    await store.store(
        memory_type="incident",
        summary="Test",
        actions_taken=actions,
    )
    rows = await store.recall_recent()
    assert json.loads(rows[0]["actions_taken"]) == actions


# ── recall_recent() ──────────────────────────────────────────────


async def test_recall_recent_empty(store: LocalStore):
    """Empty store returns empty list."""
    rows = await store.recall_recent()
    assert rows == []


async def test_recall_recent_ordered(store: LocalStore):
    """Memories are returned newest-first."""
    await store.store(memory_type="incident", summary="Old")
    await store.store(memory_type="incident", summary="New")
    rows = await store.recall_recent()
    assert rows[0]["summary"] == "New"
    assert rows[1]["summary"] == "Old"


async def test_recall_recent_type_filter(store: LocalStore):
    """memory_type filter returns only matching records."""
    await store.store(memory_type="incident", summary="Incident")
    await store.store(memory_type="pattern", summary="Pattern")
    rows = await store.recall_recent(memory_type="pattern")
    assert len(rows) == 1
    assert rows[0]["summary"] == "Pattern"


async def test_recall_recent_limit(store: LocalStore):
    """Limit parameter caps returned results."""
    for i in range(5):
        await store.store(memory_type="incident", summary=f"Event {i}")
    rows = await store.recall_recent(limit=3)
    assert len(rows) == 3


# ── recall_by_id() ───────────────────────────────────────────────


async def test_recall_by_id_found(store: LocalStore):
    """recall_by_id returns the matching record."""
    local_id = await store.store(memory_type="incident", summary="Find me")
    row = await store.recall_by_id(local_id)
    assert row is not None
    assert row["summary"] == "Find me"


async def test_recall_by_id_not_found(store: LocalStore):
    """recall_by_id returns None for non-existent ID."""
    row = await store.recall_by_id(9999)
    assert row is None


# ── search_fts() ─────────────────────────────────────────────────


async def test_search_fts_finds_match(store: LocalStore):
    """FTS5 search finds matching summaries."""
    await store.store(memory_type="incident", summary="Service OOM restart")
    await store.store(memory_type="incident", summary="Redis connection timeout")
    results = await store.search_fts("Service")
    assert len(results) >= 1
    assert any("Service" in r["summary"] for r in results)


async def test_search_fts_no_match(store: LocalStore):
    """FTS5 search returns empty on no match."""
    await store.store(memory_type="incident", summary="Service OOM restart")
    results = await store.search_fts("PostgreSQL")
    assert results == []


async def test_search_fts_searches_reasoning(store: LocalStore):
    """FTS5 search also matches reasoning field."""
    await store.store(
        memory_type="incident",
        summary="Service down",
        reasoning="Caused by memory leak in monitoring-service",
    )
    results = await store.search_fts("memory leak")
    assert len(results) >= 1


async def test_search_fts_limit(store: LocalStore):
    """FTS5 search respects limit parameter."""
    for i in range(5):
        await store.store(memory_type="incident", summary=f"Service event {i}")
    results = await store.search_fts("Service", limit=2)
    assert len(results) <= 2


# ── detect_patterns() ────────────────────────────────────────────


async def test_detect_patterns_below_threshold(store: LocalStore):
    """No patterns returned when frequency < threshold."""
    await store.store(memory_type="incident", summary="One-off event")
    patterns = await store.detect_patterns(min_frequency=3)
    assert patterns == []


async def test_detect_patterns_above_threshold(store: LocalStore):
    """Repeated events are detected as patterns."""
    for _ in range(4):
        await store.store(
            memory_type="incident",
            summary="Service OOM restart",
            outcome="resolved",
            root_cause="memory_leak",
        )
    patterns = await store.detect_patterns(min_frequency=3)
    assert len(patterns) >= 1
    assert patterns[0]["frequency"] >= 3


async def test_detect_patterns_excludes_checks(store: LocalStore):
    """check-type memories are excluded from pattern detection."""
    for _ in range(5):
        await store.store(memory_type="check", summary="Routine check")
    patterns = await store.detect_patterns(min_frequency=3)
    assert patterns == []


# ── find_past_fix() ──────────────────────────────────────────────


async def test_find_past_fix_no_history(store: LocalStore):
    """Returns None when no matching history exists."""
    result = await store.find_past_fix("unknown_cause")
    assert result is None


async def test_find_past_fix_below_occurrence_threshold(store: LocalStore):
    """Returns None when occurrences below threshold."""
    for _ in range(2):  # below default min_occurrences=3
        await store.store(
            memory_type="incident",
            summary="Test",
            root_cause="oom",
            actions_taken=[{"action": "restart"}],
            outcome="resolved",
        )
    result = await store.find_past_fix("oom")
    assert result is None


async def test_find_past_fix_success(store: LocalStore):
    """Returns the past fix when thresholds are met."""
    for _ in range(4):
        await store.store(
            memory_type="incident",
            summary="Service OOM",
            root_cause="oom",
            actions_taken=[{"action": "restart"}],
            outcome="resolved",
        )
    result = await store.find_past_fix("oom")
    assert result is not None
    assert result["action"] == "restart"
    assert result["success_rate"] >= 0.75


async def test_find_past_fix_low_success_rate(store: LocalStore):
    """Returns None when success rate is below threshold."""
    # 1 success + 3 failures = 25% rate
    await store.store(
        memory_type="incident",
        summary="Test",
        root_cause="flaky",
        actions_taken=[{"action": "restart"}],
        outcome="resolved",
    )
    for _ in range(3):
        await store.store(
            memory_type="incident",
            summary="Test",
            root_cause="flaky",
            actions_taken=[{"action": "restart"}],
            outcome="failed",
        )
    result = await store.find_past_fix("flaky", min_occurrences=3)
    assert result is None


# ── Sync queue operations ────────────────────────────────────────


async def test_mark_synced_updates_pg_id(store: LocalStore):
    """mark_synced sets pg_id and synced_at on the memory."""
    local_id = await store.store(memory_type="incident", summary="Test")
    await store.mark_synced(local_id, target_tier=3, pg_id=42)
    row = await store.recall_by_id(local_id)
    assert row is not None
    assert row["pg_id"] == 42
    assert row["synced_at"] is not None


async def test_mark_synced_qdrant_sets_embedded_at(store: LocalStore):
    """mark_synced for tier 4 (Qdrant) sets embedded_at."""
    local_id = await store.store(memory_type="incident", summary="Test")
    await store.mark_synced(local_id, target_tier=4)
    row = await store.recall_by_id(local_id)
    assert row is not None
    assert row["embedded_at"] is not None


async def test_mark_sync_failed_increments_attempts(store: LocalStore):
    """mark_sync_failed bumps the attempt counter."""
    local_id = await store.store(memory_type="incident", summary="Test")
    await store.mark_sync_failed(local_id, target_tier=3)
    pending = await store.get_pending_sync()
    pg_entry = [e for e in pending if e["target_tier"] == 3][0]
    assert pg_entry["attempts"] == 1


async def test_mark_sync_failed_marks_failed_after_max_attempts(store: LocalStore):
    """After 5 failures, status changes to 'failed'."""
    local_id = await store.store(memory_type="incident", summary="Test")
    for _ in range(5):
        await store.mark_sync_failed(local_id, target_tier=3)
    pending = await store.get_pending_sync()
    # Should no longer appear in pending (status='failed' or attempts>=5)
    pg_entries = [e for e in pending if e["memory_id"] == local_id and e["target_tier"] == 3]
    assert len(pg_entries) == 0


async def test_get_pending_sync_limit(store: LocalStore):
    """get_pending_sync respects limit."""
    for _ in range(5):
        await store.store(memory_type="incident", summary="Test")
    pending = await store.get_pending_sync(limit=3)
    assert len(pending) <= 3


# ── warm_from_pg() ───────────────────────────────────────────────


async def test_warm_from_pg_inserts(store: LocalStore):
    """warm_from_pg populates local store from PG records."""
    rows = [
        {
            "id": 100,
            "memory_type": "incident",
            "summary": "From PG",
            "trigger": "",
            "context": {},
            "reasoning": "",
            "actions_taken": [],
            "outcome": "resolved",
            "tokens_used": 0,
            "model": "",
            "created_at": "2026-01-01T00:00:00",
        },
    ]
    count = await store.warm_from_pg(rows)
    assert count == 1
    stats = await store.stats()
    assert stats["total_memories"] == 1


async def test_warm_from_pg_skips_duplicates(store: LocalStore):
    """warm_from_pg skips rows already present (same pg_id)."""
    rows = [
        {
            "id": 100,
            "memory_type": "incident",
            "summary": "From PG",
            "trigger": "",
            "context": {},
            "reasoning": "",
            "actions_taken": [],
            "outcome": "resolved",
            "tokens_used": 0,
            "model": "",
            "created_at": "2026-01-01T00:00:00",
        },
    ]
    await store.warm_from_pg(rows)
    count = await store.warm_from_pg(rows)  # second time
    assert count == 0
    stats = await store.stats()
    assert stats["total_memories"] == 1


# ── audit_log() ──────────────────────────────────────────────────


async def test_audit_log_writes(store: LocalStore):
    """audit_log writes to local_audit_log table."""
    await store.audit_log("memory_store", "store", detail="test")
    # Verify by storing + recalling (audit_log is write-only, so check via stats)
    # Use direct conn access — safe because check_same_thread=False
    import sqlite3

    conn = sqlite3.connect(str(store.db_path))
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM local_audit_log").fetchall()
    conn.close()
    assert len(rows) == 1
    assert dict(rows[0])["tool"] == "memory_store"


# ── stats() ──────────────────────────────────────────────────────


async def test_stats_empty(store: LocalStore):
    """stats() on empty store returns zeroes."""
    stats = await store.stats()
    assert stats["total_memories"] == 0
    assert stats["pending_sync"] == 0
    assert stats["failed_sync"] == 0
    assert stats["by_type"] == {}


async def test_stats_reflects_data(store: LocalStore):
    """stats() reflects stored data accurately."""
    await store.store(memory_type="incident", summary="A")
    await store.store(memory_type="incident", summary="B")
    await store.store(memory_type="pattern", summary="C")
    stats = await store.stats()
    assert stats["total_memories"] == 3
    assert stats["by_type"]["incident"] == 2
    assert stats["by_type"]["pattern"] == 1
    assert stats["pending_sync"] == 6  # 3 records × 2 tiers


# ── close() ──────────────────────────────────────────────────────


async def test_close_safe_on_uninitialized():
    """close() on an uninitialized store doesn't crash."""
    store = LocalStore(project="test", db_path=Path("/tmp/nonexistent.db"))
    await store.close()  # should not raise
