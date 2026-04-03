# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for PatternLibrary — PostgreSQL + Qdrant cross-room fix patterns."""

import time
from unittest.mock import AsyncMock, MagicMock, patch

from maude.healing.pattern_library import (
    _COLLECTION_RETRY_COOLDOWN,
    PatternLibrary,
    SharedPattern,
    _row_to_pattern,
)

# ── SharedPattern dataclass ──────────────────────────────────────────


def test_shared_pattern_defaults():
    p = SharedPattern()
    assert p.id is None
    assert p.source_room == ""
    assert p.pattern_type == "fix"
    assert p.trigger_signature == ""
    assert p.resolution == ""
    assert p.applicable_rooms == []
    assert p.success_count == 1
    assert p.score == 0.0


# ── _row_to_pattern ──────────────────────────────────────────────────


def test_row_to_pattern_with_list():
    row = {
        "id": 1,
        "source_room": "monitoring",
        "pattern_type": "fix",
        "trigger_signature": "datasource timeout",
        "resolution": "restart my-service",
        "applicable_rooms": ["monitoring", "my-service"],
        "success_count": 3,
    }
    p = _row_to_pattern(row)
    assert p.id == 1
    assert p.source_room == "monitoring"
    assert p.applicable_rooms == ["monitoring", "my-service"]
    assert p.success_count == 3


def test_row_to_pattern_with_pg_array_string():
    row = {
        "id": 2,
        "source_room": "my-service",
        "pattern_type": "fix",
        "trigger_signature": "PLC timeout",
        "resolution": "restart PLC poller",
        "applicable_rooms": "{monitoring,my-service}",
        "success_count": 1,
    }
    p = _row_to_pattern(row)
    assert p.applicable_rooms == ["monitoring", "my-service"]


def test_row_to_pattern_with_empty_array():
    row = {
        "id": 3,
        "source_room": "redis",
        "pattern_type": "fix",
        "trigger_signature": "memory spike",
        "resolution": "flush expired keys",
        "applicable_rooms": [],
        "success_count": 5,
    }
    p = _row_to_pattern(row)
    assert p.applicable_rooms == []


# ── contribute_pattern ───────────────────────────────────────────────


async def test_contribute_pattern_new_insert():
    """New pattern is inserted into PG and embedded in Qdrant."""
    lib = PatternLibrary()

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=None)  # no existing
    mock_pool.fetchval = AsyncMock(return_value=42)
    lib._db._pool = mock_pool
    lib._collection_ready = True

    fake_embedding = [0.1] * 1024
    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    lib._qdrant = mock_qdrant

    with patch.object(lib, "_embed", return_value=fake_embedding):
        result = await lib.contribute_pattern(
            source_room="monitoring",
            trigger_signature="datasource timeout",
            resolution="restart my-service",
            applicable_rooms=["monitoring", "my-service"],
        )

    assert result == 42
    mock_pool.fetchval.assert_called_once()
    mock_qdrant.upsert.assert_called_once()

    # Verify Qdrant payload
    upsert_call = mock_qdrant.upsert.call_args
    points = upsert_call[1]["points"]
    payload = points[0].payload
    assert payload["pg_id"] == 42
    assert payload["source_room"] == "monitoring"
    assert payload["trigger_signature"] == "datasource timeout"
    assert payload["resolution"] == "restart my-service"
    assert payload["applicable_rooms"] == ["monitoring", "my-service"]


async def test_contribute_pattern_increments_existing():
    """When trigger_signature already exists, success_count is incremented."""
    lib = PatternLibrary()

    existing_row = {
        "id": 10,
        "source_room": "monitoring",
        "pattern_type": "fix",
        "trigger_signature": "datasource timeout",
        "resolution": "restart my-service",
        "applicable_rooms": ["monitoring"],
        "success_count": 3,
    }
    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=existing_row)
    mock_pool.execute = AsyncMock()
    lib._db._pool = mock_pool

    result = await lib.contribute_pattern(
        source_room="my-service",
        trigger_signature="datasource timeout",
        resolution="restart my-service",
    )

    assert result == 10
    mock_pool.execute.assert_called_once()
    # Should not call fetchval (insert) since it found existing
    mock_pool.fetchval.assert_not_called()


async def test_contribute_pattern_pool_unavailable():
    """Returns None when PostgreSQL is unavailable."""
    lib = PatternLibrary()

    with patch.object(lib, "_ensure_pool", return_value=None):
        result = await lib.contribute_pattern(
            source_room="monitoring",
            trigger_signature="test",
            resolution="test fix",
        )

    assert result is None


async def test_contribute_pattern_insert_failure():
    """Returns None when INSERT fails."""
    lib = PatternLibrary()

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=None)  # no existing
    mock_pool.fetchval = AsyncMock(side_effect=Exception("insert failed"))
    lib._db._pool = mock_pool

    result = await lib.contribute_pattern(
        source_room="monitoring",
        trigger_signature="test",
        resolution="test fix",
    )

    assert result is None


async def test_contribute_pattern_qdrant_failure_still_returns_id():
    """Pattern is stored in PG even when Qdrant embedding fails."""
    lib = PatternLibrary()

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=None)
    mock_pool.fetchval = AsyncMock(return_value=99)
    lib._db._pool = mock_pool
    lib._collection_ready = True

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock(side_effect=Exception("qdrant down"))
    lib._qdrant = mock_qdrant

    fake_embedding = [0.1] * 1024

    with patch.object(lib, "_embed", return_value=fake_embedding):
        result = await lib.contribute_pattern(
            source_room="monitoring",
            trigger_signature="test",
            resolution="test fix",
        )

    assert result == 99  # PG insert succeeded despite Qdrant failure


# ── find_pattern ─────────────────────────────────────────────────────


async def test_find_pattern_semantic_search():
    """Qdrant semantic search returns matching patterns."""
    lib = PatternLibrary()
    lib._collection_ready = True

    fake_embedding = [0.1] * 1024

    hit = MagicMock()
    hit.score = 0.92
    hit.payload = {
        "pg_id": 5,
        "source_room": "monitoring",
        "pattern_type": "fix",
        "trigger_signature": "datasource connection timeout",
        "resolution": "restart my-service service",
        "applicable_rooms": ["monitoring", "my-service"],
        "success_count": 7,
    }

    query_resp = MagicMock()
    query_resp.points = [hit]

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(return_value=query_resp)
    lib._qdrant = mock_qdrant

    with patch.object(lib, "_embed", return_value=fake_embedding):
        patterns = await lib.find_pattern("postgres connection refused")

    assert len(patterns) == 1
    assert patterns[0].id == 5
    assert patterns[0].score == 0.92
    assert patterns[0].resolution == "restart my-service service"
    assert patterns[0].applicable_rooms == ["monitoring", "my-service"]


async def test_find_pattern_sql_fallback():
    """Falls back to SQL exact match when Qdrant returns nothing."""
    lib = PatternLibrary()

    # Qdrant unavailable
    with patch.object(lib, "_ensure_collection", return_value=False):
        sql_row = {
            "id": 8,
            "source_room": "redis",
            "pattern_type": "fix",
            "trigger_signature": "memory spike",
            "resolution": "flush expired keys",
            "applicable_rooms": [],
            "success_count": 2,
        }
        mock_pool = AsyncMock()
        mock_pool.fetchrow = AsyncMock(return_value=sql_row)
        lib._db._pool = mock_pool

        patterns = await lib.find_pattern("memory spike")

    assert len(patterns) == 1
    assert patterns[0].id == 8
    assert patterns[0].trigger_signature == "memory spike"
    assert patterns[0].score == 0.0  # no semantic score from SQL


async def test_find_pattern_room_boost():
    """Patterns applicable to the requesting room sort higher."""
    lib = PatternLibrary()
    lib._collection_ready = True

    fake_embedding = [0.1] * 1024

    hit1 = MagicMock()
    hit1.score = 0.90
    hit1.payload = {
        "pg_id": 1,
        "source_room": "my-service",
        "pattern_type": "fix",
        "trigger_signature": "PLC timeout",
        "resolution": "restart poller",
        "applicable_rooms": ["my-service"],
        "success_count": 2,
    }
    hit2 = MagicMock()
    hit2.score = 0.85
    hit2.payload = {
        "pg_id": 2,
        "source_room": "monitoring",
        "pattern_type": "fix",
        "trigger_signature": "datasource timeout",
        "resolution": "restart my-service",
        "applicable_rooms": ["monitoring"],
        "success_count": 5,
    }

    query_resp = MagicMock()
    query_resp.points = [hit1, hit2]

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(return_value=query_resp)
    lib._qdrant = mock_qdrant

    with patch.object(lib, "_embed", return_value=fake_embedding):
        patterns = await lib.find_pattern("timeout error", room="monitoring")

    # hit2 should be first because it's applicable to monitoring
    assert patterns[0].id == 2
    assert patterns[1].id == 1


async def test_find_pattern_empty_results():
    """Returns empty list when nothing matches."""
    lib = PatternLibrary()

    with patch.object(lib, "_ensure_collection", return_value=False):
        mock_pool = AsyncMock()
        mock_pool.fetchrow = AsyncMock(return_value=None)
        lib._db._pool = mock_pool

        patterns = await lib.find_pattern("unknown trigger")

    assert patterns == []


async def test_find_pattern_qdrant_search_exception():
    """Qdrant exception falls through to SQL fallback gracefully."""
    lib = PatternLibrary()
    lib._collection_ready = True

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(side_effect=Exception("qdrant error"))
    lib._qdrant = mock_qdrant

    sql_row = {
        "id": 15,
        "source_room": "monitoring",
        "pattern_type": "fix",
        "trigger_signature": "datasource timeout",
        "resolution": "restart",
        "applicable_rooms": [],
        "success_count": 1,
    }
    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=sql_row)
    lib._db._pool = mock_pool

    with patch.object(lib, "_embed", return_value=fake_embedding):
        patterns = await lib.find_pattern("datasource timeout")

    assert len(patterns) == 1
    assert patterns[0].id == 15


# ── applicable_patterns ──────────────────────────────────────────────


async def test_applicable_patterns_filters_by_room():
    """Returns patterns where room is in applicable_rooms or rooms is empty."""
    lib = PatternLibrary()

    mock_rows = [
        {
            "id": 1,
            "source_room": "monitoring",
            "pattern_type": "fix",
            "trigger_signature": "disk full",
            "resolution": "clean logs",
            "applicable_rooms": ["monitoring", "loki"],
            "success_count": 10,
        },
        {
            "id": 2,
            "source_room": "redis",
            "pattern_type": "fix",
            "trigger_signature": "OOM",
            "resolution": "flush keys",
            "applicable_rooms": [],
            "success_count": 3,
        },
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    lib._db._pool = mock_pool

    patterns = await lib.applicable_patterns("monitoring", limit=5)

    assert len(patterns) == 2
    assert patterns[0].id == 1
    assert patterns[0].applicable_rooms == ["monitoring", "loki"]
    assert patterns[1].id == 2
    mock_pool.fetch.assert_called_once()


async def test_applicable_patterns_pool_unavailable():
    """Returns empty list when PostgreSQL is unavailable."""
    lib = PatternLibrary()

    with patch.object(lib, "_ensure_pool", return_value=None):
        patterns = await lib.applicable_patterns("monitoring")

    assert patterns == []


async def test_applicable_patterns_query_failure():
    """Returns empty list on SQL exception."""
    lib = PatternLibrary()

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=Exception("timeout"))
    lib._db._pool = mock_pool

    patterns = await lib.applicable_patterns("monitoring")
    assert patterns == []


# ── _ensure_pool ─────────────────────────────────────────────────────


async def test_ensure_pool_returns_existing():
    lib = PatternLibrary()
    mock_pool = AsyncMock()
    lib._db._pool = mock_pool
    result = await lib._ensure_pool()
    assert result is mock_pool


async def test_ensure_pool_returns_none_on_failure():
    lib = PatternLibrary()
    with (
        patch("maude.db.pool.pg_pool_kwargs", return_value={
            "host": "localhost", "port": 5432, "user": "support",
            "password": "pw", "database": "agent", "min_size": 1, "max_size": 2,
        }),
        patch(
            "maude.db.pool.asyncpg.create_pool",
            side_effect=Exception("conn refused"),
        ),
    ):
        result = await lib._ensure_pool()
    assert result is None


# ── _ensure_collection ───────────────────────────────────────────────


async def test_ensure_collection_already_ready():
    lib = PatternLibrary()
    lib._collection_ready = True
    result = await lib._ensure_collection()
    assert result is True


async def test_ensure_collection_creates_when_missing():
    lib = PatternLibrary()

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=False)
    mock_qdrant.create_collection = AsyncMock()
    lib._qdrant = mock_qdrant

    result = await lib._ensure_collection()
    assert result is True
    assert lib._collection_ready is True
    mock_qdrant.create_collection.assert_called_once()


async def test_ensure_collection_cooldown_blocks_retry():
    lib = PatternLibrary()

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(side_effect=Exception("refused"))
    lib._qdrant = mock_qdrant

    # First call fails
    result = await lib._ensure_collection()
    assert result is False
    assert lib._collection_failed_at > 0

    # Second call during cooldown
    mock_qdrant.collection_exists.reset_mock()
    result = await lib._ensure_collection()
    assert result is False
    mock_qdrant.collection_exists.assert_not_called()


async def test_ensure_collection_retries_after_cooldown():
    lib = PatternLibrary()

    lib._collection_failed_at = time.monotonic() - _COLLECTION_RETRY_COOLDOWN - 1

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=True)
    lib._qdrant = mock_qdrant

    result = await lib._ensure_collection()
    assert result is True
    assert lib._collection_ready is True


# ── close ────────────────────────────────────────────────────────────


async def test_close_cleans_up():
    lib = PatternLibrary()

    mock_pool = AsyncMock()
    mock_pool.close = AsyncMock()
    lib._db._pool = mock_pool

    mock_qdrant = AsyncMock()
    mock_qdrant.close = AsyncMock()
    lib._qdrant = mock_qdrant

    mock_vllm = AsyncMock()
    mock_vllm.close = AsyncMock()
    lib._vllm = mock_vllm

    await lib.close()

    mock_pool.close.assert_called_once()
    mock_qdrant.close.assert_called_once()
    mock_vllm.close.assert_called_once()
    assert lib._db._pool is None
    assert lib._qdrant is None


# ── _embed ───────────────────────────────────────────────────────────


async def test_embed_success():
    lib = PatternLibrary()

    expected_vec = [0.1] * 1024
    mock_resp = MagicMock()
    mock_resp.embeddings = [expected_vec]
    lib._vllm.embed = AsyncMock(return_value=mock_resp)

    result = await lib._embed("test text")
    assert result == expected_vec


async def test_embed_exception():
    lib = PatternLibrary()
    lib._vllm.embed = AsyncMock(side_effect=Exception("vllm down"))

    result = await lib._embed("test text")
    assert result is None


async def test_embed_wrong_dimensions():
    lib = PatternLibrary()

    wrong_vec = [0.1] * 384
    mock_resp = MagicMock()
    mock_resp.embeddings = [wrong_vec]
    lib._vllm.embed = AsyncMock(return_value=mock_resp)

    result = await lib._embed("test text")
    assert result is None
