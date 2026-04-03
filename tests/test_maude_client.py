# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for MaudeClient — memory-as-a-service proxy."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.healing.maude_client import MaudeClient, MaudeMemory


@pytest.fixture
def client() -> MaudeClient:
    return MaudeClient(project="redis")


def test_init_sets_project(client: MaudeClient) -> None:
    assert client.project == "redis"
    assert client._store is None


def test_maude_memory_fields() -> None:
    mem = MaudeMemory(
        id=42,
        project="monitoring",
        memory_type="incident",
        summary="Datasource timeout",
        outcome="resolved",
        score=0.95,
    )
    assert mem.id == 42
    assert mem.project == "monitoring"
    assert mem.score == 0.95


@pytest.mark.asyncio
async def test_store_memory_delegates(client: MaudeClient) -> None:
    mock_store = MagicMock()
    mock_store.store_memory = AsyncMock(return_value=7)
    client._store = mock_store

    result = await client.store_memory(
        project="redis",
        memory_type="incident",
        summary="Redis OOM",
        trigger="health_check",
        reasoning="maxmemory exceeded",
        outcome="resolved",
    )
    assert result == 7
    mock_store.store_memory.assert_awaited_once()
    call_kwargs = mock_store.store_memory.call_args
    assert call_kwargs.kwargs["project"] == "redis"
    assert call_kwargs.kwargs["memory_type"] == "incident"


@pytest.mark.asyncio
async def test_recall_recent_converts(client: MaudeClient) -> None:
    mock_mem = MagicMock()
    mock_mem.id = 1
    mock_mem.project = "redis"
    mock_mem.memory_type = "incident"
    mock_mem.trigger = "health"
    mock_mem.reasoning = "oom"
    mock_mem.actions_taken = []
    mock_mem.outcome = "resolved"
    mock_mem.summary = "Redis OOM"
    mock_mem.score = 0.0
    mock_mem.created_at = None

    mock_store = MagicMock()
    mock_store.recall_recent = AsyncMock(return_value=[mock_mem])
    client._store = mock_store

    result = await client.recall_recent("redis", limit=5)
    assert len(result) == 1
    assert isinstance(result[0], MaudeMemory)
    assert result[0].summary == "Redis OOM"


@pytest.mark.asyncio
async def test_recall_similar_none_on_unavailable(client: MaudeClient) -> None:
    mock_store = MagicMock()
    mock_store.recall_similar = AsyncMock(return_value=None)
    client._store = mock_store

    result = await client.recall_similar("redis", "oom error", limit=3)
    assert result is None


@pytest.mark.asyncio
async def test_recall_similar_converts(client: MaudeClient) -> None:
    mock_mem = MagicMock()
    mock_mem.id = 2
    mock_mem.project = "redis"
    mock_mem.memory_type = "pattern"
    mock_mem.trigger = ""
    mock_mem.reasoning = ""
    mock_mem.actions_taken = []
    mock_mem.outcome = "resolved"
    mock_mem.summary = "High memory usage"
    mock_mem.score = 0.92
    mock_mem.created_at = None

    mock_store = MagicMock()
    mock_store.recall_similar = AsyncMock(return_value=[mock_mem])
    client._store = mock_store

    result = await client.recall_similar("redis", "memory pressure", limit=3)
    assert result is not None
    assert len(result) == 1
    assert result[0].score == 0.92


@pytest.mark.asyncio
async def test_embed_and_store_delegates(client: MaudeClient) -> None:
    mock_store = MagicMock()
    mock_store.embed_and_store = AsyncMock(return_value=True)
    client._store = mock_store

    ok = await client.embed_and_store(
        memory_id=7,
        summary="Redis OOM",
        memory_type="incident",
        outcome="resolved",
    )
    assert ok is True
    mock_store.embed_and_store.assert_awaited_once()


@pytest.mark.asyncio
async def test_recall_by_id_found(client: MaudeClient) -> None:
    mock_mem = MagicMock()
    mock_mem.id = 42
    mock_mem.project = "redis"
    mock_mem.memory_type = "incident"
    mock_mem.trigger = ""
    mock_mem.reasoning = ""
    mock_mem.actions_taken = []
    mock_mem.outcome = "resolved"
    mock_mem.summary = "Test"
    mock_mem.score = 0.0
    mock_mem.created_at = None

    mock_store = MagicMock()
    mock_store.recall_by_id = AsyncMock(return_value=mock_mem)
    client._store = mock_store

    result = await client.recall_by_id(42, "redis")
    assert result is not None
    assert result.id == 42


@pytest.mark.asyncio
async def test_recall_by_id_not_found(client: MaudeClient) -> None:
    mock_store = MagicMock()
    mock_store.recall_by_id = AsyncMock(return_value=None)
    client._store = mock_store

    result = await client.recall_by_id(999, "redis")
    assert result is None


@pytest.mark.asyncio
async def test_close_cleans_up(client: MaudeClient) -> None:
    mock_store = MagicMock()
    mock_store.close = AsyncMock()
    client._store = mock_store

    await client.close()
    mock_store.close.assert_awaited_once()
    assert client._store is None


@pytest.mark.asyncio
async def test_close_noop_when_no_store(client: MaudeClient) -> None:
    # Should not raise
    await client.close()
    assert client._store is None


def test_lazy_init_creates_store(client: MaudeClient) -> None:
    """_get_store() lazily creates a MemoryStore on first call."""
    client._store = None
    with patch("maude.memory.store.MemoryStore") as MockStore:
        MockStore.return_value = MagicMock()
        store = client._get_store()
        assert store is not None
        assert client._store is not None
        MockStore.assert_called_once_with(project="redis")


def test_lazy_init_reuses_store(client: MaudeClient) -> None:
    """_get_store() returns the same instance on repeated calls."""
    sentinel = MagicMock()
    client._store = sentinel
    assert client._get_store() is sentinel
