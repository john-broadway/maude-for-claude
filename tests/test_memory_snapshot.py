# Tests for memory snapshot — export/import for fleet cloning.
# Version: 1.0.0
# Created: 2026-04-02 16:30 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Tests for maude.memory.snapshot — export and import room memory."""

from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest

from maude.memory.snapshot import SNAPSHOT_VERSION, MemorySnapshot

# ── Helpers ──────────────────────────────────────────────────────────


def _make_memory_row(row_id=1, project="grafana", memory_type="incident"):
    return {
        "id": row_id,
        "project": project,
        "memory_type": memory_type,
        "trigger": "health_loop",
        "context": {"disk_percent": 85},
        "reasoning": "Disk was high",
        "actions_taken": [{"tool": "service_restart"}],
        "outcome": "resolved",
        "summary": "Restarted after disk alert",
        "tokens_used": 150,
        "model": "qwen3-32b",
        "root_cause": "disk_pressure",
        "created_at": datetime(2026, 4, 1, tzinfo=timezone.utc),
    }


def _make_pattern_row(row_id=1, project="grafana"):
    return {
        "id": row_id,
        "project": project,
        "pattern_type": "recurring",
        "trigger_pattern": "disk | full | grafana",
        "resolution_pattern": "resolved",
        "frequency": 5,
        "source_memory_ids": [1, 2, 3, 4, 5],
        "created_at": datetime(2026, 4, 1, tzinfo=timezone.utc),
        "updated_at": datetime(2026, 4, 1, tzinfo=timezone.utc),
    }


# ── export_project ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_export_project():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(
        side_effect=[
            [_make_memory_row(1), _make_memory_row(2, memory_type="check")],
            [_make_pattern_row(1)],
        ]
    )
    snapshot._db._pool = mock_pool

    bundle = await snapshot.export_project("grafana")

    assert bundle["version"] == SNAPSHOT_VERSION
    assert bundle["source_project"] == "grafana"
    assert bundle["memory_count"] == 2
    assert bundle["pattern_count"] == 1
    assert len(bundle["memories"]) == 2
    assert bundle["memories"][0]["original_id"] == 1
    assert bundle["memories"][0]["memory_type"] == "incident"
    assert bundle["patterns"][0]["trigger_pattern"] == "disk | full | grafana"


@pytest.mark.asyncio
async def test_export_empty_project():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=[[], []])
    snapshot._db._pool = mock_pool

    bundle = await snapshot.export_project("empty-room")

    assert bundle["memory_count"] == 0
    assert bundle["pattern_count"] == 0


@pytest.mark.asyncio
async def test_export_pool_unavailable():
    snapshot = MemorySnapshot()
    snapshot._db.get = AsyncMock(return_value=None)

    with pytest.raises(RuntimeError, match="PostgreSQL unavailable"):
        await snapshot.export_project("grafana")


@pytest.mark.asyncio
async def test_export_serializes_json_strings():
    """Context and actions stored as JSON strings are properly parsed."""
    snapshot = MemorySnapshot()
    row = _make_memory_row()
    row["context"] = '{"key": "value"}'
    row["actions_taken"] = '[{"tool": "restart"}]'
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=[[row], []])
    snapshot._db._pool = mock_pool

    bundle = await snapshot.export_project("grafana")

    assert bundle["memories"][0]["context"] == {"key": "value"}
    assert bundle["memories"][0]["actions_taken"] == [{"tool": "restart"}]


# ── import_project ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_import_project():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    # Memory inserts return new IDs 100, 101
    # Pattern insert returns new ID 200
    mock_pool.fetchval = AsyncMock(side_effect=[100, 101, 200])
    snapshot._db._pool = mock_pool

    bundle = {
        "version": SNAPSHOT_VERSION,
        "source_project": "grafana",
        "memories": [
            {"original_id": 1, "memory_type": "incident", "summary": "Test 1"},
            {"original_id": 2, "memory_type": "check", "summary": "Test 2"},
        ],
        "patterns": [
            {
                "original_id": 10,
                "pattern_type": "recurring",
                "trigger_pattern": "disk | full",
                "resolution_pattern": "resolved",
                "frequency": 3,
                "source_memory_ids": [1, 2],
            }
        ],
    }

    stats = await snapshot.import_project(bundle, target_project="grafana-pa")

    assert stats["memories_imported"] == 2
    assert stats["patterns_imported"] == 1
    assert stats["errors"] == 0

    # Verify target project is used, not source
    first_call = mock_pool.fetchval.call_args_list[0]
    assert first_call[0][1] == "grafana-pa"

    # Verify source_memory_ids are remapped
    pattern_call = mock_pool.fetchval.call_args_list[2]
    remapped_ids = pattern_call[0][6]
    assert 100 in remapped_ids  # old 1 → new 100
    assert 101 in remapped_ids  # old 2 → new 101


@pytest.mark.asyncio
async def test_import_wrong_version():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    snapshot._db._pool = mock_pool

    with pytest.raises(ValueError, match="Unsupported snapshot version"):
        await snapshot.import_project({"version": 999}, target_project="test")


@pytest.mark.asyncio
async def test_import_pool_unavailable():
    snapshot = MemorySnapshot()
    snapshot._db.get = AsyncMock(return_value=None)

    with pytest.raises(RuntimeError, match="PostgreSQL unavailable"):
        await snapshot.import_project(
            {"version": SNAPSHOT_VERSION, "memories": []},
            target_project="test",
        )


@pytest.mark.asyncio
async def test_import_handles_partial_failure():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    call_count = 0

    async def mock_fetchval(sql, *args):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise Exception("insert failed")
        return call_count * 10

    mock_pool.fetchval = mock_fetchval
    snapshot._db._pool = mock_pool

    bundle = {
        "version": SNAPSHOT_VERSION,
        "memories": [
            {"original_id": 1, "summary": "Fails"},
            {"original_id": 2, "summary": "Succeeds"},
        ],
        "patterns": [],
    }

    stats = await snapshot.import_project(bundle, target_project="test")

    assert stats["memories_imported"] == 1
    assert stats["errors"] == 1


@pytest.mark.asyncio
async def test_import_empty_bundle():
    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    snapshot._db._pool = mock_pool

    bundle = {"version": SNAPSHOT_VERSION, "memories": [], "patterns": []}
    stats = await snapshot.import_project(bundle, target_project="test")

    assert stats["memories_imported"] == 0
    assert stats["patterns_imported"] == 0
    assert stats["errors"] == 0


# ── Round-trip ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_bundle_is_json_serializable():
    """Snapshot bundles must be JSON-serializable for file transport."""
    import json

    snapshot = MemorySnapshot()
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=[[_make_memory_row()], [_make_pattern_row()]])
    snapshot._db._pool = mock_pool

    bundle = await snapshot.export_project("grafana")

    # Should not raise
    serialized = json.dumps(bundle)
    assert isinstance(serialized, str)

    # Round-trip
    deserialized = json.loads(serialized)
    assert deserialized["version"] == SNAPSHOT_VERSION
    assert len(deserialized["memories"]) == 1


# ── close ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_delegates_to_pool():
    snapshot = MemorySnapshot()
    snapshot._db = AsyncMock()
    await snapshot.close()
    snapshot._db.close.assert_awaited_once()
