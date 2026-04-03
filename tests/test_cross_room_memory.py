# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for CrossRoomMemory — Redis caching + PostgreSQL queries."""

import json
from datetime import datetime
from unittest.mock import AsyncMock, patch

import pytest

from maude.coordination.cross_room_memory import _CACHE_TTL, CrossRoomMemory
from maude.testing import FakeRedis


@pytest.fixture
def fake_redis():
    return FakeRedis()


@pytest.fixture
def memory_no_redis():
    """CrossRoomMemory without Redis (no caching)."""
    return CrossRoomMemory(db_host="localhost", database="agent")


@pytest.fixture
def memory_with_redis(fake_redis):
    """CrossRoomMemory with Redis caching."""
    return CrossRoomMemory(db_host="localhost", database="agent", redis=fake_redis)


def _fake_rows(*dicts: dict) -> list:
    """Create fake asyncpg Record-like dicts."""

    class FakeRecord(dict):
        pass

    return [FakeRecord(d) for d in dicts]


# -- Pool initialization --


@pytest.mark.asyncio
async def test_no_pool_returns_empty(memory_no_redis):
    """Without a PG pool, all queries return empty."""
    with patch.object(memory_no_redis, "_ensure_pool", new_callable=AsyncMock, return_value=None):
        assert await memory_no_redis.recent_activity() == []
        assert await memory_no_redis.all_rooms_summary() == []
        assert await memory_no_redis.recent_incidents() == []
        assert await memory_no_redis.recent_escalations() == []
        assert await memory_no_redis.recent_remediations() == []
        assert await memory_no_redis.recent_restarts() == []
        assert await memory_no_redis.fleet_stats() == {}


# -- Cache behavior --


@pytest.mark.asyncio
async def test_cache_get_returns_none_without_redis(memory_no_redis):
    """_cache_get returns None when no Redis configured."""
    result = await memory_no_redis._cache_get("any:key")
    assert result is None


@pytest.mark.asyncio
async def test_cache_set_noop_without_redis(memory_no_redis):
    """_cache_set is a no-op when no Redis configured."""
    await memory_no_redis._cache_set("any:key", [{"foo": "bar"}])
    # Should not raise


@pytest.mark.asyncio
async def test_cache_get_returns_cached_data(memory_with_redis, fake_redis):
    """_cache_get returns parsed JSON from Redis."""
    data = [{"id": 1, "project": "my-service"}]
    await fake_redis.set("test:key", json.dumps(data))

    result = await memory_with_redis._cache_get("test:key")
    assert result == data


@pytest.mark.asyncio
async def test_cache_set_stores_data(memory_with_redis, fake_redis):
    """_cache_set stores JSON in Redis."""
    data = [{"id": 1, "summary": "test"}]
    await memory_with_redis._cache_set("test:key", data)

    raw = await fake_redis.get("test:key")
    assert raw is not None
    assert json.loads(raw) == data


# -- recent_activity caching --


@pytest.mark.asyncio
async def test_recent_activity_returns_cached(memory_with_redis, fake_redis):
    """recent_activity() returns cached result without hitting PG."""
    cached_data = [{"id": 1, "project": "my-service", "summary": "cached"}]
    await fake_redis.set("fd:activity:60", json.dumps(cached_data))

    result = await memory_with_redis.recent_activity(minutes=60)
    assert result == cached_data


@pytest.mark.asyncio
async def test_recent_activity_caches_on_miss(memory_with_redis, fake_redis):
    """recent_activity() caches PG results on miss."""
    rows = _fake_rows(
        {"id": 1, "project": "my-service", "summary": "fresh", "created_at": "2026-01-01T00:00:00"},
    )
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=rows)

    with patch.object(
        memory_with_redis,
        "_ensure_pool",
        new_callable=AsyncMock,
        return_value=mock_pool,
    ):
        result = await memory_with_redis.recent_activity(minutes=60)

    assert len(result) == 1
    assert result[0]["project"] == "my-service"

    # Verify it was cached
    raw = await fake_redis.get("fd:activity:60")
    assert raw is not None
    cached = json.loads(raw)
    assert cached[0]["project"] == "my-service"


# -- all_rooms_summary caching --


@pytest.mark.asyncio
async def test_all_rooms_summary_returns_cached(memory_with_redis, fake_redis):
    """all_rooms_summary() returns cached result."""
    cached_data = [{"project": "my-service", "total_runs": 5}]
    await fake_redis.set("fd:summary:60", json.dumps(cached_data))

    result = await memory_with_redis.all_rooms_summary(minutes=60)
    assert result == cached_data


@pytest.mark.asyncio
async def test_all_rooms_summary_caches_on_miss(memory_with_redis, fake_redis):
    """all_rooms_summary() caches PG results on miss."""
    rows = _fake_rows({"project": "my-service", "total_runs": 10, "resolved": 8})
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=rows)

    with patch.object(
        memory_with_redis,
        "_ensure_pool",
        new_callable=AsyncMock,
        return_value=mock_pool,
    ):
        result = await memory_with_redis.all_rooms_summary(minutes=30)

    assert len(result) == 1
    raw = await fake_redis.get("fd:summary:30")
    assert raw is not None


# -- recent_incidents caching --


@pytest.mark.asyncio
async def test_recent_incidents_returns_cached(memory_with_redis, fake_redis):
    """recent_incidents() returns cached result."""
    cached_data = [{"id": 5, "project": "monitoring", "outcome": "escalated"}]
    await fake_redis.set("fd:incidents:60", json.dumps(cached_data))

    result = await memory_with_redis.recent_incidents(minutes=60)
    assert result == cached_data


@pytest.mark.asyncio
async def test_recent_incidents_caches_on_miss(memory_with_redis, fake_redis):
    """recent_incidents() caches PG results on miss."""
    rows = _fake_rows(
        {
            "id": 5,
            "project": "monitoring",
            "outcome": "escalated",
            "created_at": "2026-01-01T00:00:00",
        },
    )
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=rows)

    with patch.object(
        memory_with_redis,
        "_ensure_pool",
        new_callable=AsyncMock,
        return_value=mock_pool,
    ):
        result = await memory_with_redis.recent_incidents(minutes=120)

    assert len(result) == 1
    raw = await fake_redis.get("fd:incidents:120")
    assert raw is not None


# -- Non-cached methods still work --


@pytest.mark.asyncio
async def test_project_activity_no_caching(memory_with_redis):
    """project_activity() does not use caching."""
    rows = _fake_rows({"id": 1, "project": "pbs", "created_at": "2026-01-01T00:00:00"})
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=rows)

    with patch.object(
        memory_with_redis,
        "_ensure_pool",
        new_callable=AsyncMock,
        return_value=mock_pool,
    ):
        result = await memory_with_redis.project_activity("pbs", minutes=60)

    assert len(result) == 1
    mock_pool.fetch.assert_awaited_once()


@pytest.mark.asyncio
async def test_fleet_stats_no_pool(memory_no_redis):
    """fleet_stats() returns empty dict without pool."""
    with patch.object(memory_no_redis, "_ensure_pool", new_callable=AsyncMock, return_value=None):
        result = await memory_no_redis.fleet_stats()
    assert result == {}


# -- close() --


@pytest.mark.asyncio
async def test_close_with_pool():
    """close() closes the connection pool."""
    mem = CrossRoomMemory(db_host="localhost")
    mock_pool = AsyncMock()
    mem._db._pool = mock_pool

    await mem.close()
    mock_pool.close.assert_awaited_once()
    assert mem._db._pool is None


@pytest.mark.asyncio
async def test_close_without_pool():
    """close() is safe when pool is None."""
    mem = CrossRoomMemory(db_host="localhost")
    await mem.close()  # Should not raise


# -- _row_to_dict --


def test_row_to_dict_converts_datetime():
    """_row_to_dict converts datetime to ISO string."""
    now = datetime(2026, 1, 15, 12, 30, 0)

    class FakeRecord(dict):
        pass

    row = FakeRecord({"id": 1, "created_at": now, "project": "test"})
    result = CrossRoomMemory._row_to_dict(row)
    assert result["created_at"] == "2026-01-15T12:30:00"
    assert result["project"] == "test"


def test_cache_ttl_is_30_seconds():
    """Cache TTL should be 30 seconds as designed."""
    assert _CACHE_TTL == 30
