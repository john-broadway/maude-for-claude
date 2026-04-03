# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for EventPublisher — PG NOTIFY fire-and-forget + Redis Streams."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.infra.events import CHANNEL, MAX_PAYLOAD, EventPublisher, RedisEventPublisher
from maude.testing import FakeRedis


@pytest.fixture
def publisher() -> EventPublisher:
    return EventPublisher(project="my-service", db_host="localhost")


# ── Construction ──────────────────────────────────────────────────


def test_init(publisher: EventPublisher):
    assert publisher.project == "my-service"
    assert publisher._conn is None


# ── publish() without connection ──────────────────────────────────


@pytest.mark.asyncio
async def test_publish_without_connection_attempts_connect(publisher: EventPublisher):
    """publish() should try to connect if not connected."""
    with patch.object(publisher, "connect", new_callable=AsyncMock) as mock_connect:
        # connect fails silently, publish returns False
        result = await publisher.publish("test_event", {"key": "value"})
        mock_connect.assert_awaited_once()
        assert result is False


# ── publish() with connection ─────────────────────────────────────


@pytest.mark.asyncio
async def test_publish_success(publisher: EventPublisher):
    """publish() should send NOTIFY with correct channel and payload."""
    mock_conn = AsyncMock()
    publisher._conn = mock_conn

    result = await publisher.publish("health_status_changed", {"status": "unhealthy"})

    assert result is True
    mock_conn.execute.assert_awaited_once()
    call_args = mock_conn.execute.call_args
    assert call_args[0][0] == "SELECT pg_notify($1, $2)"
    assert call_args[0][1] == CHANNEL
    payload = call_args[0][2]
    assert '"room": "my-service"' in payload
    assert '"event": "health_status_changed"' in payload
    assert '"status": "unhealthy"' in payload


@pytest.mark.asyncio
async def test_publish_with_room_override(publisher: EventPublisher):
    """publish() should use room override if provided."""
    mock_conn = AsyncMock()
    publisher._conn = mock_conn

    await publisher.publish("test", {}, room="monitoring")
    payload = mock_conn.execute.call_args[0][2]
    assert '"room": "monitoring"' in payload


@pytest.mark.asyncio
async def test_publish_truncates_large_payload(publisher: EventPublisher):
    """Payloads over MAX_PAYLOAD should be truncated."""
    mock_conn = AsyncMock()
    publisher._conn = mock_conn

    large_data = {"big": "x" * (MAX_PAYLOAD + 1000)}
    result = await publisher.publish("big_event", large_data)

    assert result is True
    payload = mock_conn.execute.call_args[0][2]
    assert len(payload) <= MAX_PAYLOAD + 500  # Allow for truncated wrapper


@pytest.mark.asyncio
async def test_publish_resets_conn_on_failure(publisher: EventPublisher):
    """Connection errors should reset _conn so next call reconnects."""
    mock_conn = AsyncMock()
    mock_conn.execute.side_effect = Exception("connection lost")
    publisher._conn = mock_conn

    result = await publisher.publish("test", {})
    assert result is False
    assert publisher._conn is None


# ── close() ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_when_connected(publisher: EventPublisher):
    mock_conn = AsyncMock()
    publisher._conn = mock_conn

    await publisher.close()
    mock_conn.close.assert_awaited_once()
    assert publisher._conn is None


@pytest.mark.asyncio
async def test_close_when_not_connected(publisher: EventPublisher):
    """close() should be safe when not connected."""
    await publisher.close()  # Should not raise
    assert publisher._conn is None


# ── Coverage: connect() ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_connect_success(publisher: EventPublisher):
    """connect() establishes asyncpg connection."""
    mock_conn = AsyncMock()
    db_creds = {"postgres": {"port": 5432, "user": "support", "password": "secret"}}

    with (
        patch("maude.infra.events.load_credentials", return_value=db_creds),
        patch(
            "maude.infra.events.asyncpg.connect",
            new_callable=AsyncMock, return_value=mock_conn,
        ),
    ):
        await publisher.connect()

    assert publisher._conn is mock_conn


@pytest.mark.asyncio
async def test_connect_failure(publisher: EventPublisher):
    """connect() sets _conn to None on failure."""
    db_creds = {"postgres": {"port": 5432, "user": "support", "password": "secret"}}

    with (
        patch("maude.infra.events.load_credentials", return_value=db_creds),
        patch(
            "maude.infra.events.asyncpg.connect",
            new_callable=AsyncMock,
            side_effect=ConnectionRefusedError("no db"),
        ),
    ):
        await publisher.connect()

    assert publisher._conn is None


@pytest.mark.asyncio
async def test_connect_skips_if_already_connected(publisher: EventPublisher):
    """connect() short-circuits when already connected."""
    mock_conn = AsyncMock()
    publisher._conn = mock_conn

    target = "maude.infra.events.asyncpg.connect"
    with patch(target, new_callable=AsyncMock) as mock_connect:
        await publisher.connect()

    mock_connect.assert_not_awaited()
    assert publisher._conn is mock_conn


# ── Coverage: close() exception handling ─────────────────────────


@pytest.mark.asyncio
async def test_close_handles_exception(publisher: EventPublisher):
    """close() suppresses exceptions during conn.close()."""
    mock_conn = AsyncMock()
    mock_conn.close = AsyncMock(side_effect=RuntimeError("close failed"))
    publisher._conn = mock_conn

    await publisher.close()  # Should not raise

    assert publisher._conn is None


# ── Coverage: resolve_db_host used in connect ──────────────────────


@pytest.mark.asyncio
async def test_connect_uses_resolve_db_host():
    """connect() uses resolve_db_host when no db_host set."""
    pub = EventPublisher(project="test")
    mock_conn = AsyncMock()
    db_creds = {"postgres": {"port": 5432, "user": "support", "password": "secret"}}

    with (
        patch("maude.infra.events.resolve_db_host", return_value="resolved.host"),
        patch("maude.infra.events.load_credentials", return_value=db_creds),
        patch(
            "maude.infra.events.asyncpg.connect",
            new_callable=AsyncMock, return_value=mock_conn,
        ),
    ):
        await pub.connect()

    assert pub._conn is mock_conn


# ── RedisEventPublisher ──────────────────────────────────────────


@pytest.fixture
def fake_redis():
    r = FakeRedis()
    # Simulate the internal _redis attribute that RedisEventPublisher accesses
    r._redis = MagicMock()
    r._redis.xadd = AsyncMock(return_value="0-1")
    return r


@pytest.fixture
def redis_publisher(fake_redis) -> RedisEventPublisher:
    pg_fallback = EventPublisher(project="test", db_host="localhost")
    return RedisEventPublisher(
        project="test",
        redis_client=fake_redis,
        pg_fallback=pg_fallback,
    )


@pytest.mark.asyncio
async def test_redis_publisher_uses_redis(redis_publisher, fake_redis):
    """RedisEventPublisher publishes to Redis Streams when available."""
    result = await redis_publisher.publish("test_event", {"key": "value"})
    assert result is True
    fake_redis._redis.xadd.assert_awaited_once()


@pytest.mark.asyncio
async def test_redis_publisher_falls_back_to_pg(fake_redis):
    """RedisEventPublisher falls back to PG NOTIFY when Redis XADD fails."""
    fake_redis._redis.xadd = AsyncMock(side_effect=Exception("Redis down"))

    pg_fallback = MagicMock()
    pg_fallback.publish = AsyncMock(return_value=True)

    pub = RedisEventPublisher(project="test", redis_client=fake_redis, pg_fallback=pg_fallback)
    result = await pub.publish("test_event", {"key": "value"})

    assert result is True
    pg_fallback.publish.assert_awaited_once()


@pytest.mark.asyncio
async def test_redis_publisher_no_redis_uses_pg():
    """RedisEventPublisher uses PG when no Redis client."""
    pg_fallback = MagicMock()
    pg_fallback.publish = AsyncMock(return_value=True)

    pub = RedisEventPublisher(project="test", redis_client=None, pg_fallback=pg_fallback)
    result = await pub.publish("test_event")

    assert result is True
    pg_fallback.publish.assert_awaited_once()


@pytest.mark.asyncio
async def test_redis_publisher_close():
    """close() closes the PG fallback."""
    pg_fallback = MagicMock()
    pg_fallback.close = AsyncMock()

    pub = RedisEventPublisher(project="test", pg_fallback=pg_fallback)
    await pub.close()
    pg_fallback.close.assert_awaited_once()
