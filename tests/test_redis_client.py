# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.redis_client.MaudeRedis (using FakeRedis)."""

import pytest

from maude.testing import FakeRedis


@pytest.fixture
def redis():
    return FakeRedis()


async def test_connect(redis):
    assert await redis.connect() is True
    assert redis.available is True


async def test_get_set(redis):
    assert await redis.get("missing") is None
    assert await redis.set("key1", "value1") is True
    assert await redis.get("key1") == "value1"


async def test_set_with_ttl(redis):
    assert await redis.set("ephemeral", "data", ttl=30) is True
    assert await redis.get("ephemeral") == "data"


async def test_delete(redis):
    await redis.set("to_delete", "val")
    assert await redis.delete("to_delete") is True
    assert await redis.get("to_delete") is None


async def test_delete_missing(redis):
    assert await redis.delete("nonexistent") is True


async def test_rate_check_always_allows(redis):
    result = await redis.rate_check("rate:test", limit=1, window=60)
    assert result["allowed"] is True
    assert result["remaining"] == 0


async def test_publish_event(redis):
    entry_id = await redis.publish_event("events", {"type": "test", "data": "hello"})
    assert entry_id is not None
    assert entry_id.startswith("0-")


async def test_read_events(redis):
    await redis.publish_event("events", {"type": "a"})
    await redis.publish_event("events", {"type": "b"})

    events = await redis.read_events("events", count=10)
    assert len(events) == 2
    assert events[0]["type"] == "a"
    assert events[1]["type"] == "b"


async def test_read_events_empty_stream(redis):
    events = await redis.read_events("empty_stream")
    assert events == []


async def test_broadcast(redis):
    count = await redis.broadcast("notifications", "hello world")
    assert count == 1


async def test_close_is_noop(redis):
    await redis.close()
    # Should still work after close (it's a fake)
    assert await redis.set("after_close", "ok") is True
