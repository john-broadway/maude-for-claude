"""Tests for memory store — PostgreSQL + Qdrant with graceful degradation (vLLM embeddings)."""

import time
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

from maude.memory.store import (
    _COLLECTION_RETRY_TIERS,
    Memory,
    MemoryStore,
    _parse_delete_count,
    _row_to_memory,
)

# ── Memory dataclass ────────────────────────────────────────────────


def test_memory_defaults():
    m = Memory()
    assert m.id is None
    assert m.project == ""
    assert m.score == 0.0
    assert m.actions_taken == []
    assert m.context == {}


# ── _row_to_memory ──────────────────────────────────────────────────


def test_row_to_memory_with_json_strings():
    """Simulate asyncpg returning JSON columns as strings."""
    row = {
        "id": 42,
        "project": "grafana",
        "memory_type": "incident",
        "trigger": "health_loop",
        "context": '{"disk_percent": 85}',
        "reasoning": "Disk was high",
        "actions_taken": '[{"tool": "service_restart"}]',
        "outcome": "resolved",
        "summary": "Restarted after disk alert",
        "tokens_used": 150,
        "model": "claude-haiku-4",
        "created_at": datetime(2026, 1, 30, tzinfo=timezone.utc),
    }
    m = _row_to_memory(row)
    assert m.id == 42
    assert m.project == "grafana"
    assert m.context == {"disk_percent": 85}
    assert len(m.actions_taken) == 1
    assert m.actions_taken[0]["tool"] == "service_restart"


def test_row_to_memory_with_dict_columns():
    """Simulate asyncpg returning JSON columns as dicts (normal case)."""
    row = {
        "id": 1,
        "project": "grafana",
        "memory_type": "check",
        "trigger": "schedule",
        "context": {"healthy": True},
        "reasoning": "",
        "actions_taken": [],
        "outcome": "no_action",
        "summary": "All clear",
        "tokens_used": 0,
        "model": "",
        "created_at": None,
    }
    m = _row_to_memory(row)
    assert m.context == {"healthy": True}
    assert m.actions_taken == []


# ── MemoryStore — PostgreSQL ────────────────────────────────────────


async def test_store_memory_success():
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=42)
    store._db._pool = mock_pool

    row_id = await store.store_memory(
        project="grafana",
        memory_type="incident",
        summary="Restarted service",
        context={"reason": "memory high"},
        trigger="health_loop",
        reasoning="Memory at 95%",
        outcome="resolved",
    )

    assert row_id == 42
    mock_pool.fetchval.assert_called_once()


async def test_store_memory_with_conversation():
    """Conversation JSONB is passed as the 11th parameter to INSERT."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=99)
    store._db._pool = mock_pool

    conversation = [
        {"role": "user", "content": "Check service health"},
        {
            "role": "assistant",
            "content": "Calling service_status",
            "tool_calls": [{"id": "tc1", "name": "service_status", "arguments": {}}],
        },
        {
            "role": "user",
            "content": [{"type": "tool_result", "tool_use_id": "tc1", "content": "active"}],
        },
        {"role": "assistant", "content": "Service is healthy."},
    ]

    row_id = await store.store_memory(
        project="grafana",
        memory_type="check",
        summary="All healthy",
        conversation=conversation,
    )

    assert row_id == 99
    # The 12th positional arg to fetchval is the conversation JSON string
    call_args = mock_pool.fetchval.call_args[0]
    assert len(call_args) == 13  # SQL + 12 params
    assert call_args[11] == ""  # root_cause default
    import json

    conv_arg = json.loads(call_args[12])
    assert len(conv_arg) == 4
    assert conv_arg[0]["role"] == "user"


async def test_store_memory_without_conversation():
    """When conversation is None, the 12th param is None (not a JSON string)."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=50)
    store._db._pool = mock_pool

    await store.store_memory(
        project="grafana",
        memory_type="check",
        summary="All healthy",
    )

    call_args = mock_pool.fetchval.call_args[0]
    assert call_args[11] == ""  # root_cause default (empty string)
    assert call_args[12] is None  # No conversation → NULL in DB


async def test_store_memory_returns_none_when_pool_unavailable():
    store = MemoryStore(project="grafana")
    # _pool stays None, _ensure_pool will fail

    with patch.object(store, "_ensure_pool", return_value=None):
        row_id = await store.store_memory(
            project="grafana",
            memory_type="incident",
            summary="test",
        )

    assert row_id is None


async def test_recall_recent_success():
    store = MemoryStore(project="grafana")

    mock_rows = [
        {
            "id": 1,
            "project": "grafana",
            "memory_type": "incident",
            "trigger": "health",
            "context": {},
            "reasoning": "test",
            "actions_taken": [],
            "outcome": "resolved",
            "summary": "Fixed datasource",
            "tokens_used": 100,
            "model": "claude",
            "created_at": datetime(2026, 1, 30, tzinfo=timezone.utc),
        }
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    store._db._pool = mock_pool

    memories = await store.recall_recent("grafana", memory_type="incident", limit=5)

    assert len(memories) == 1
    assert memories[0].summary == "Fixed datasource"
    assert memories[0].outcome == "resolved"


async def test_recall_recent_returns_empty_when_pool_unavailable():
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_pool", return_value=None):
        memories = await store.recall_recent("grafana")

    assert memories == []


# ── MemoryStore — Qdrant ────────────────────────────────────────────


async def test_recall_similar_returns_none_when_embedding_fails():
    store = MemoryStore(project="grafana")

    with patch.object(store, "_embed", return_value=None):
        memories = await store.recall_similar("grafana", "test query")

    assert memories is None


async def test_embed_and_store_success():
    store = MemoryStore(project="grafana")
    store._collection_ready = True  # Skip _ensure_collection

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Test memory",
            memory_type="incident",
            outcome="resolved",
        )

    assert result is True
    # 2 upserts: per-room collection + vault
    assert mock_qdrant.upsert.call_count == 2


async def test_embed_and_store_fails_gracefully():
    store = MemoryStore(project="grafana")

    with patch.object(store, "_embed", return_value=None):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Test memory",
            memory_type="incident",
            outcome="resolved",
        )

    assert result is False


# ── MemoryStore — close ─────────────────────────────────────────────


async def test_close_cleans_up():
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.close = AsyncMock()
    store._db._pool = mock_pool

    mock_qdrant = AsyncMock()
    mock_qdrant.close = AsyncMock()
    store._qdrant = mock_qdrant

    mock_vllm = AsyncMock()
    mock_vllm.close = AsyncMock()
    store._vllm = mock_vllm

    await store.close()

    mock_pool.close.assert_called_once()
    mock_qdrant.close.assert_called_once()
    mock_vllm.close.assert_called_once()
    assert store._db._pool is None
    assert store._qdrant is None


# ── resolve_infra_hosts fallback (via common) ────────────────────


# ── _ensure_pool ──────────────────────────────────────────────────


async def test_ensure_pool_returns_existing():
    """If pool is already set, _ensure_pool returns it immediately."""
    store = MemoryStore(project="grafana")
    mock_pool = AsyncMock()
    store._db._pool = mock_pool
    result = await store._ensure_pool()
    assert result is mock_pool


async def test_ensure_pool_returns_none_on_connection_failure():
    """When asyncpg.create_pool raises, _ensure_pool returns None."""
    store = MemoryStore(project="grafana")
    with (
        patch(
            "maude.db.pool.pg_pool_kwargs",
            return_value={
                "host": "192.0.2.177",
                "port": 5432,
                "user": "support",
                "password": "pw",
                "database": "agent",
                "min_size": 1,
                "max_size": 3,
            },
        ),
        patch("maude.db.pool.asyncpg.create_pool", side_effect=Exception("conn refused")),
    ):
        result = await store._ensure_pool()
    assert result is None
    assert store._db._pool is None


async def test_ensure_pool_success():
    """Successful pool creation stores and returns the pool."""
    store = MemoryStore(project="grafana")
    fake_pool = MagicMock()

    async def _fake_create_pool(**kwargs):
        return fake_pool

    with (
        patch(
            "maude.db.pool.pg_pool_kwargs",
            return_value={
                "host": "192.0.2.177",
                "port": 5432,
                "user": "support",
                "password": "pw",
                "database": "agent",
                "min_size": 1,
                "max_size": 3,
            },
        ),
        patch("maude.db.pool.asyncpg.create_pool", side_effect=_fake_create_pool),
    ):
        result = await store._ensure_pool()
    assert result is fake_pool
    assert store._db._pool is fake_pool


# ── _ensure_collection ────────────────────────────────────────────


async def test_ensure_collection_already_ready():
    store = MemoryStore(project="grafana")
    store._collection_ready = True
    result = await store._ensure_collection()
    assert result is True


async def test_ensure_collection_creates_when_missing():
    """When collection doesn't exist, it is created."""
    store = MemoryStore(project="grafana")

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=False)
    mock_qdrant.create_collection = AsyncMock()
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is True
    assert store._collection_ready is True
    mock_qdrant.create_collection.assert_called_once()


async def test_ensure_collection_exists_already():
    """When collection already exists, no creation needed."""
    store = MemoryStore(project="grafana")

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=True)
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is True
    assert store._collection_ready is True
    mock_qdrant.create_collection.assert_not_called()


async def test_ensure_collection_handles_error():
    """When SDK call raises, returns False gracefully."""
    store = MemoryStore(project="grafana")

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(side_effect=Exception("connection refused"))
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is False
    assert store._collection_ready is False


# ── store_memory exception path ───────────────────────────────────


async def test_store_memory_handles_exception():
    """When pool.fetchval raises, store_memory returns None."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(side_effect=Exception("unique violation"))
    store._db._pool = mock_pool

    row_id = await store.store_memory(
        project="grafana",
        memory_type="incident",
        summary="Test",
    )
    assert row_id is None


# ── recall_recent — all types path ────────────────────────────────


async def test_recall_recent_all_types():
    """When memory_type is None, RECALL_ALL_SQL is used (2 params)."""
    store = MemoryStore(project="grafana")

    mock_rows = [
        {
            "id": 10,
            "project": "grafana",
            "memory_type": "check",
            "trigger": "schedule",
            "context": {},
            "reasoning": "",
            "actions_taken": [],
            "outcome": "no_action",
            "summary": "All clear",
            "tokens_used": 0,
            "model": "",
            "created_at": None,
        }
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    store._db._pool = mock_pool

    memories = await store.recall_recent("grafana", memory_type=None, limit=10)

    assert len(memories) == 1
    assert memories[0].memory_type == "check"
    # RECALL_ALL_SQL takes 2 params: project, limit
    call_args = mock_pool.fetch.call_args[0]
    assert call_args[0] == store.RECALL_ALL_SQL
    assert call_args[1] == "grafana"
    assert call_args[2] == 10


async def test_recall_recent_handles_exception():
    """When pool.fetch raises, recall_recent returns empty list."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=Exception("timeout"))
    store._db._pool = mock_pool

    memories = await store.recall_recent("grafana", memory_type="incident")
    assert memories == []


# ── recall_by_id ──────────────────────────────────────────────────


async def test_recall_by_id_success():
    store = MemoryStore(project="grafana")

    mock_row = {
        "id": 42,
        "project": "grafana",
        "memory_type": "incident",
        "trigger": "health_loop",
        "context": {"disk": 95},
        "reasoning": "High disk",
        "actions_taken": [],
        "outcome": "resolved",
        "summary": "Cleared old logs",
        "tokens_used": 100,
        "model": "claude",
        "created_at": datetime(2026, 1, 30, tzinfo=timezone.utc),
    }
    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=mock_row)
    store._db._pool = mock_pool

    memory = await store.recall_by_id(42, "grafana")
    assert memory is not None
    assert memory.id == 42
    assert memory.summary == "Cleared old logs"


async def test_recall_by_id_not_found():
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=None)
    store._db._pool = mock_pool

    memory = await store.recall_by_id(999, "grafana")
    assert memory is None


async def test_recall_by_id_pool_unavailable():
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_pool", return_value=None):
        memory = await store.recall_by_id(42, "grafana")
    assert memory is None


async def test_recall_by_id_exception():
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(side_effect=Exception("conn lost"))
    store._db._pool = mock_pool

    memory = await store.recall_by_id(42, "grafana")
    assert memory is None


# ── recall_similar — full success path ────────────────────────────


async def test_recall_similar_full_success():
    """Full recall_similar flow: ensure_collection, embed, SDK search."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    hit1 = MagicMock()
    hit1.score = 0.95
    hit1.payload = {
        "pg_id": 42,
        "project": "grafana",
        "memory_type": "incident",
        "summary": "Restarted grafana",
        "outcome": "resolved",
        "created_at": "2026-01-30T12:00:00Z",
    }
    hit2 = MagicMock()
    hit2.score = 0.80
    hit2.payload = {
        "pg_id": 43,
        "project": "grafana",
        "memory_type": "pattern",
        "summary": "Datasource timeout",
        "outcome": "resolved",
    }

    query_resp = MagicMock()
    query_resp.points = [hit1, hit2]

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(return_value=query_resp)
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        memories = await store.recall_similar("grafana", "grafana restart")

    assert memories is not None
    assert len(memories) == 2
    assert memories[0].id == 42
    assert memories[0].score == 0.95
    assert memories[0].summary == "Restarted grafana"
    assert memories[1].id == 43
    mock_qdrant.query_points.assert_called_once()


async def test_recall_similar_collection_failure():
    """When _ensure_collection fails, recall_similar returns None."""
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_collection", return_value=False):
        result = await store.recall_similar("grafana", "test")
    assert result is None


async def test_recall_similar_exception_returns_none():
    """When SDK search raises, recall_similar returns None."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(side_effect=Exception("qdrant down"))
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        result = await store.recall_similar("grafana", "test")
    assert result is None


# ── embed_and_store — failure paths ───────────────────────────────


async def test_embed_and_store_collection_failure():
    """When _ensure_collection fails, embed_and_store returns False."""
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_collection", return_value=False):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Test",
            memory_type="incident",
            outcome="resolved",
        )
    assert result is False


async def test_embed_and_store_exception():
    """When SDK upsert raises, embed_and_store returns False."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock(side_effect=Exception("qdrant error"))
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Test",
            memory_type="incident",
            outcome="resolved",
        )
    assert result is False


# ── _embed ────────────────────────────────────────────────────────


async def test_embed_success():
    """Successful embedding returns the vector."""
    store = MemoryStore(project="grafana")

    expected_vec = [0.1] * 1024
    mock_resp = MagicMock()
    mock_resp.embeddings = [expected_vec]
    store._vllm = MagicMock()
    store._vllm.embed = AsyncMock(return_value=mock_resp)

    result = await store._embed("test text")
    assert result == expected_vec


async def test_embed_wrong_dimensions():
    """When embedding has unexpected dimensions, returns None."""
    store = MemoryStore(project="grafana")

    wrong_vec = [0.1] * 384  # Wrong dimension (384 instead of 1024)
    mock_resp = MagicMock()
    mock_resp.embeddings = [wrong_vec]
    store._vllm = MagicMock()
    store._vllm.embed = AsyncMock(return_value=mock_resp)

    result = await store._embed("test text")
    assert result is None


async def test_embed_empty_response():
    """When embeddings list is empty, returns None."""
    store = MemoryStore(project="grafana")

    mock_resp = MagicMock()
    mock_resp.embeddings = []
    store._vllm = MagicMock()
    store._vllm.embed = AsyncMock(return_value=mock_resp)

    result = await store._embed("test text")
    assert result is None


async def test_embed_exception():
    """When VLLMClient call fails, _embed returns None."""
    store = MemoryStore(project="grafana")

    store._vllm = MagicMock()
    store._vllm.embed = AsyncMock(side_effect=Exception("vllm down"))

    result = await store._embed("test text")
    assert result is None


# ── _ensure_collection cooldown ──────────────────────────────────


async def test_ensure_collection_cooldown_blocks_retry():
    """After failure, _ensure_collection returns False during cooldown."""
    store = MemoryStore(project="grafana")

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(side_effect=Exception("refused"))
    store._qdrant = mock_qdrant

    # First call fails and sets cooldown
    result = await store._ensure_collection()
    assert result is False
    assert store._collection_failed_at > 0

    # Second call during cooldown returns False immediately (no SDK call)
    mock_qdrant.collection_exists.reset_mock()
    result = await store._ensure_collection()
    assert result is False
    mock_qdrant.collection_exists.assert_not_called()


async def test_ensure_collection_retries_after_cooldown():
    """After cooldown expires, _ensure_collection retries the SDK call."""
    store = MemoryStore(project="grafana")

    # Simulate a past failure beyond cooldown
    store._collection_failed_at = time.monotonic() - _COLLECTION_RETRY_TIERS[0] - 1

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=True)
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is True
    assert store._collection_ready is True
    assert store._collection_failed_at == 0.0
    mock_qdrant.collection_exists.assert_called_once()


async def test_ensure_collection_cooldown_resets_on_new_failure():
    """A retry after cooldown that fails again resets the cooldown timer."""
    store = MemoryStore(project="grafana")

    # Simulate a past failure beyond cooldown
    store._collection_failed_at = time.monotonic() - _COLLECTION_RETRY_TIERS[0] - 1
    old_failed_at = store._collection_failed_at

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(side_effect=Exception("still down"))
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is False
    # The failed_at timestamp should be updated (newer than old one)
    assert store._collection_failed_at > old_failed_at


# ── backfill_embeddings ──────────────────────────────────────────


async def test_backfill_embeddings_success():
    """Backfill embeds recent memories from PostgreSQL into Qdrant."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    mock_rows = [
        {
            "id": 100,
            "summary": "Fixed datasource",
            "memory_type": "incident",
            "outcome": "resolved",
        },
        {"id": 101, "summary": "Cleared old logs", "memory_type": "pattern", "outcome": "resolved"},
    ]

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    store._db._pool = mock_pool

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed_batch", return_value=[fake_embedding, fake_embedding]):
        count = await store.backfill_embeddings(limit=10)

    assert count == 2
    # 4 upserts: 2 per-room + 2 vault
    assert mock_qdrant.upsert.call_count == 4


async def test_backfill_embeddings_pool_unavailable():
    """Returns 0 when PostgreSQL is unavailable."""
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_pool", return_value=None):
        count = await store.backfill_embeddings()

    assert count == 0


async def test_backfill_embeddings_collection_unavailable():
    """Returns 0 when Qdrant collection is unavailable."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    store._db._pool = mock_pool

    with patch.object(store, "_ensure_collection", return_value=False):
        count = await store.backfill_embeddings()

    assert count == 0


async def test_backfill_embeddings_partial_failure():
    """Counts only successfully embedded memories."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    mock_rows = [
        {"id": 200, "summary": "Good memory", "memory_type": "incident", "outcome": "resolved"},
        {"id": 201, "summary": "Bad memory", "memory_type": "incident", "outcome": "failed"},
    ]

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    store._db._pool = mock_pool

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    store._qdrant = mock_qdrant

    # _embed_batch returns None for "Bad memory", embedding for "Good memory"
    with patch.object(store, "_embed_batch", return_value=[fake_embedding, None]):
        count = await store.backfill_embeddings()

    assert count == 1  # Only the "Good memory" succeeded
    # 2 upserts: per-room + vault for the one success
    assert mock_qdrant.upsert.call_count == 2


async def test_backfill_embeddings_query_failure():
    """Returns 0 when the backfill SQL query fails."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=Exception("query timeout"))
    store._db._pool = mock_pool

    count = await store.backfill_embeddings()
    assert count == 0


# ── embed_and_store — enrichment fields ───────────────────────────


async def test_embed_and_store_with_enriched_payload():
    """Extra kwargs (actions_summary, root_cause, tools_used) appear in Qdrant payload."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Restarted grafana-server",
            memory_type="incident",
            outcome="resolved",
            actions_summary="restart: succeeded",
            root_cause="service_crash",
            tools_used=["restart", "service_health"],
        )

    assert result is True
    upsert_call = mock_qdrant.upsert.call_args
    points = upsert_call[1]["points"]
    point_payload = points[0].payload
    assert point_payload["actions_summary"] == "restart: succeeded"
    assert point_payload["root_cause"] == "service_crash"
    assert point_payload["tools_used"] == ["restart", "service_health"]


async def test_embed_and_store_without_enrichment():
    """Backward compat: no extra kwargs → no extra fields in payload."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    mock_qdrant = AsyncMock()
    mock_qdrant.upsert = AsyncMock()
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        result = await store.embed_and_store(
            memory_id=42,
            summary="Test memory",
            memory_type="incident",
            outcome="resolved",
        )

    assert result is True
    upsert_call = mock_qdrant.upsert.call_args
    points = upsert_call[1]["points"]
    point_payload = points[0].payload
    assert "actions_summary" not in point_payload
    assert "root_cause" not in point_payload
    assert "tools_used" not in point_payload


async def test_recall_similar_hydrates_enriched_fields():
    """Enriched payload fields come back in recalled Memory.reasoning."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    hit = MagicMock()
    hit.score = 0.90
    hit.payload = {
        "pg_id": 42,
        "project": "grafana",
        "memory_type": "incident",
        "summary": "Restarted grafana",
        "outcome": "resolved",
        "actions_summary": "restart: succeeded",
        "root_cause": "service_crash",
    }

    query_resp = MagicMock()
    query_resp.points = [hit]

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(return_value=query_resp)
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        memories = await store.recall_similar("grafana", "grafana restart")

    assert memories is not None
    assert len(memories) == 1
    assert "restart: succeeded" in memories[0].reasoning
    assert "service_crash" in memories[0].reasoning


async def test_recall_similar_handles_missing_enriched_fields():
    """Old points without enrichment fields still work — reasoning is empty."""
    store = MemoryStore(project="grafana")
    store._collection_ready = True

    fake_embedding = [0.1] * 1024

    hit = MagicMock()
    hit.score = 0.85
    hit.payload = {
        "pg_id": 43,
        "project": "grafana",
        "memory_type": "incident",
        "summary": "Old memory",
        "outcome": "resolved",
    }

    query_resp = MagicMock()
    query_resp.points = [hit]

    mock_qdrant = AsyncMock()
    mock_qdrant.query_points = AsyncMock(return_value=query_resp)
    store._qdrant = mock_qdrant

    with patch.object(store, "_embed", return_value=fake_embedding):
        memories = await store.recall_similar("grafana", "test")

    assert memories is not None
    assert len(memories) == 1
    assert memories[0].reasoning == ""


# ── _parse_delete_count ───────────────────────────────────────────


def test_parse_delete_count_normal():
    assert _parse_delete_count("DELETE 5") == 5


def test_parse_delete_count_zero():
    assert _parse_delete_count("DELETE 0") == 0


def test_parse_delete_count_invalid():
    assert _parse_delete_count("UNEXPECTED") == 0


def test_parse_delete_count_empty():
    assert _parse_delete_count("") == 0


# ── prune_stale_memories ─────────────────────────────────────────


async def test_prune_deletes_old_no_action_checks():
    """Old check memories with outcome='no_action' are deleted."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(return_value="DELETE 10")
    store._db._pool = mock_pool

    deleted = await store.prune_stale_memories(check_days=14, incident_days=180)

    # First call should use PRUNE_CHECK_SQL with policy retention
    first_call = mock_pool.execute.call_args_list[0]
    assert "check" in first_call[0][0].lower()
    assert "no_action" in first_call[0][0].lower()
    assert first_call[0][1] == "grafana"
    # Policy-driven: iterates all types with finite retention (check +
    # incident + escalation + trend_warning + visit + concierge +
    # relay_incoming), so total calls > 2
    assert mock_pool.execute.call_count >= 2
    assert deleted > 0


async def test_prune_preserves_pattern_and_remediation():
    """Pattern, remediation, and decision memories are never pruned (permanent)."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(return_value="DELETE 0")
    store._db._pool = mock_pool

    deleted = await store.prune_stale_memories()

    assert deleted == 0
    # Verify no call targets permanent types as the $2 memory_type param.
    # PRUNE_BY_TYPE_SQL uses positional args: ($1=project, $2=type, $3=days)
    permanent_types = {
        "pattern",
        "remediation",
        "decision",
        "escalation_investigation",
        "session_archive",
        "synthetic",
    }
    for call in mock_pool.execute.call_args_list:
        args = call[0]
        if len(args) >= 3 and isinstance(args[1], str):
            assert args[1] not in permanent_types, f"Pruned permanent type: {args[1]}"


async def test_prune_respects_policy_retention():
    """Each type is pruned using its policy retention_days, not legacy params."""
    store = MemoryStore(project="grafana")

    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(return_value="DELETE 3")
    store._db._pool = mock_pool

    await store.prune_stale_memories(check_days=7, incident_days=90)

    # Verify incident type uses policy retention (180), not incident_days param (90).
    # PRUNE_BY_TYPE_SQL args: (sql, project, type, days) — type at index 2
    incident_calls = [
        c for c in mock_pool.execute.call_args_list if len(c[0]) >= 4 and c[0][2] == "incident"
    ]
    assert len(incident_calls) == 1
    assert incident_calls[0][0][3] == 180  # policy retention_days, not 90


async def test_prune_returns_zero_when_pool_unavailable():
    """When PostgreSQL is down, prune returns 0."""
    store = MemoryStore(project="grafana")

    with patch.object(store, "_ensure_pool", return_value=None):
        deleted = await store.prune_stale_memories()

    assert deleted == 0


async def test_prune_handles_partial_failure():
    """If one query fails, the others still run."""
    store = MemoryStore(project="grafana")

    call_num = 0

    async def mock_execute(sql, *args):
        nonlocal call_num
        call_num += 1
        if call_num == 1:
            raise Exception("check query failed")
        return "DELETE 5"

    mock_pool = AsyncMock()
    mock_pool.execute = mock_execute
    store._db._pool = mock_pool

    deleted = await store.prune_stale_memories()

    # First call (check) fails, remaining types succeed — total > 0
    assert call_num > 1  # Multiple types attempted
    assert deleted > 0  # At least some non-check types pruned


# ── Embedding cache ────────────────────────────────────────────────


async def test_embed_cache_hit():
    """Second call to _embed with same text returns cached result."""
    store = MemoryStore(project="grafana")
    fake_embedding = [0.1] * 1024

    mock_vllm = AsyncMock()
    resp = MagicMock()
    resp.embeddings = [fake_embedding]
    mock_vllm.embed = AsyncMock(return_value=resp)
    store._vllm = mock_vllm

    first = await store._embed("hello world")
    second = await store._embed("hello world")

    assert first == second
    # Only one call to vLLM — second was cached
    assert mock_vllm.embed.call_count == 1


async def test_embed_cache_miss():
    """Different texts produce separate vLLM calls."""
    store = MemoryStore(project="grafana")
    fake_embedding = [0.1] * 1024

    mock_vllm = AsyncMock()
    resp = MagicMock()
    resp.embeddings = [fake_embedding]
    mock_vllm.embed = AsyncMock(return_value=resp)
    store._vllm = mock_vllm

    await store._embed("hello")
    await store._embed("world")

    assert mock_vllm.embed.call_count == 2


async def test_embed_cache_eviction():
    """Cache evicts oldest entry when full."""
    store = MemoryStore(project="grafana")
    store._embed_cache_size = 2
    fake_embedding = [0.1] * 1024

    mock_vllm = AsyncMock()
    resp = MagicMock()
    resp.embeddings = [fake_embedding]
    mock_vllm.embed = AsyncMock(return_value=resp)
    store._vllm = mock_vllm

    await store._embed("text1")
    await store._embed("text2")
    await store._embed("text3")  # should evict text1

    assert len(store._embed_cache) == 2
    # text1's key should be evicted
    key1 = store._cache_key("text1")
    assert key1 not in store._embed_cache


# ── Progressive backoff ────────────────────────────────────────────


async def test_collection_retry_progressive_backoff():
    """Retry count advances through backoff tiers."""
    store = MemoryStore(project="grafana")

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(side_effect=Exception("down"))
    store._qdrant = mock_qdrant

    # First failure
    await store._ensure_collection()
    assert store._collection_retry_count == 1

    # Still within first tier (30s) — should return False without retrying
    result = await store._ensure_collection()
    assert result is False
    assert store._collection_retry_count == 1  # unchanged

    # After first tier cooldown (30s) — retry and fail again, advancing count
    store._collection_failed_at = time.monotonic() - _COLLECTION_RETRY_TIERS[1] - 1
    await store._ensure_collection()
    assert store._collection_retry_count == 2


async def test_collection_retry_resets_on_success():
    """Successful collection check resets retry counter."""
    store = MemoryStore(project="grafana")
    store._collection_retry_count = 3
    store._collection_failed_at = time.monotonic() - _COLLECTION_RETRY_TIERS[-1] - 1

    mock_qdrant = AsyncMock()
    mock_qdrant.collection_exists = AsyncMock(return_value=True)
    store._qdrant = mock_qdrant

    result = await store._ensure_collection()
    assert result is True
    assert store._collection_retry_count == 0


# ── Batch embed ────────────────────────────────────────────────────


async def test_embed_batch_all_uncached():
    """Batch embed calls vLLM once for all texts."""
    store = MemoryStore(project="grafana")
    fake_embeddings = [[0.1] * 1024, [0.2] * 1024]

    mock_vllm = AsyncMock()
    resp = MagicMock()
    resp.embeddings = fake_embeddings
    mock_vllm.embed = AsyncMock(return_value=resp)
    store._vllm = mock_vllm

    results = await store._embed_batch(["text1", "text2"])

    assert len(results) == 2
    assert results[0] is not None
    assert results[1] is not None
    mock_vllm.embed.call_count == 1


async def test_embed_batch_with_cache_hits():
    """Batch embed skips already-cached texts."""
    store = MemoryStore(project="grafana")

    # Pre-cache one text
    cached_embedding = [0.5] * 1024
    store._embed_cache[store._cache_key("cached")] = cached_embedding

    new_embedding = [0.2] * 1024
    mock_vllm = AsyncMock()
    resp = MagicMock()
    resp.embeddings = [new_embedding]
    mock_vllm.embed = AsyncMock(return_value=resp)
    store._vllm = mock_vllm

    results = await store._embed_batch(["cached", "new_text"])

    assert results[0] == cached_embedding
    assert results[1] == new_embedding
    # Only one text sent to vLLM
    call_args = mock_vllm.embed.call_args
    assert call_args[1]["input"] == ["new_text"]


async def test_embed_batch_all_cached():
    """Batch embed returns cached results without vLLM call."""
    store = MemoryStore(project="grafana")

    store._embed_cache[store._cache_key("a")] = [0.1] * 1024
    store._embed_cache[store._cache_key("b")] = [0.2] * 1024

    mock_vllm = AsyncMock()
    store._vllm = mock_vllm

    results = await store._embed_batch(["a", "b"])

    assert len(results) == 2
    assert all(r is not None for r in results)
    mock_vllm.embed.assert_not_called()
