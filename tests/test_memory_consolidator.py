# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for MemoryConsolidator — clustering and merging old memories."""

from unittest.mock import AsyncMock, patch

from maude.memory.consolidator import (
    ConsolidationResult,
    MemoryConsolidator,
    _cluster_vectors,
    _cosine_similarity,
    _merge_summaries,
)

# ── ConsolidationResult defaults ──────────────────────────────────


def test_consolidation_result_defaults():
    r = ConsolidationResult()
    assert r.memories_scanned == 0
    assert r.clusters_found == 0
    assert r.patterns_created == 0
    assert r.memories_consolidated == 0


# ── _cosine_similarity ────────────────────────────────────────────


def test_cosine_similarity_identical():
    vec = [1.0, 0.0, 1.0]
    assert _cosine_similarity(vec, vec) > 0.999


def test_cosine_similarity_orthogonal():
    a = [1.0, 0.0, 0.0]
    b = [0.0, 1.0, 0.0]
    assert abs(_cosine_similarity(a, b)) < 0.001


def test_cosine_similarity_zero_vector():
    a = [0.0, 0.0, 0.0]
    b = [1.0, 2.0, 3.0]
    assert _cosine_similarity(a, b) == 0.0


# ── _cluster_vectors ──────────────────────────────────────────────


def test_cluster_identical_vectors():
    """Identical vectors should land in the same cluster."""
    vec = [1.0, 0.0, 0.5]
    items = [
        ({"id": 1, "summary": "a"}, vec),
        ({"id": 2, "summary": "b"}, vec),
        ({"id": 3, "summary": "c"}, vec),
    ]
    clusters = _cluster_vectors(items, threshold=0.85)
    assert len(clusters) == 1
    assert len(clusters[0]) == 3


def test_cluster_dissimilar_vectors():
    """Orthogonal vectors should form separate clusters."""
    items = [
        ({"id": 1, "summary": "a"}, [1.0, 0.0, 0.0]),
        ({"id": 2, "summary": "b"}, [0.0, 1.0, 0.0]),
        ({"id": 3, "summary": "c"}, [0.0, 0.0, 1.0]),
    ]
    clusters = _cluster_vectors(items, threshold=0.85)
    assert len(clusters) == 3


def test_cluster_threshold_boundary():
    """Slightly similar vectors below threshold form separate clusters."""
    items = [
        ({"id": 1, "summary": "a"}, [1.0, 0.0]),
        ({"id": 2, "summary": "b"}, [0.7, 0.7]),
    ]
    # Cosine similarity of [1,0] and [0.7,0.7] ~ 0.707 < 0.85
    clusters = _cluster_vectors(items, threshold=0.85)
    assert len(clusters) == 2


# ── _merge_summaries ──────────────────────────────────────────────


def test_merge_summaries_single():
    assert _merge_summaries(["only one"]) == "only one"


def test_merge_summaries_deduplicates():
    result = _merge_summaries(["same", "same", "same"])
    assert "3 occurrences" in result
    assert result.count("same") == 1  # deduped


def test_merge_summaries_caps_examples():
    summaries = [f"summary {i}" for i in range(10)]
    result = _merge_summaries(summaries)
    assert "and 7 more" in result


# ── consolidate ───────────────────────────────────────────────────


async def test_consolidate_pool_unavailable():
    """Returns empty result when PostgreSQL is down."""
    mc = MemoryConsolidator(project="monitoring")
    with patch.object(mc._db, "get", return_value=None):
        result = await mc.consolidate()
    assert result.memories_scanned == 0


async def test_consolidate_no_old_memories():
    """Returns empty result when no old memories exist."""
    mc = MemoryConsolidator(project="monitoring")
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=[])
    mc._db._pool = mock_pool

    result = await mc.consolidate()
    assert result.memories_scanned == 0


async def test_consolidate_small_clusters_skipped():
    """Clusters below min_cluster_size are not merged."""
    mc = MemoryConsolidator(project="monitoring")

    # 3 memories that are all different (will form 3 clusters of size 1)
    mock_rows = [
        {"id": i, "summary": f"unique event {i}", "memory_type": "check",
         "outcome": "no_action", "trigger": "schedule"}
        for i in range(3)
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    mc._db._pool = mock_pool

    # Return orthogonal vectors so each memory is its own cluster
    call_count = 0

    async def mock_embed(text: str) -> list[float]:
        nonlocal call_count
        vec = [0.0] * 10
        vec[call_count % 10] = 1.0
        call_count += 1
        return vec

    with patch.object(mc._store, "_embed", side_effect=mock_embed):
        result = await mc.consolidate(min_cluster_size=5)

    assert result.memories_scanned == 3
    assert result.clusters_found == 0
    assert result.patterns_created == 0


async def test_consolidate_merges_large_cluster():
    """A cluster of 5+ identical memories gets merged into a pattern."""
    mc = MemoryConsolidator(project="monitoring")

    mock_rows = [
        {"id": i, "summary": "disk space warning on monitoring",
         "memory_type": "check", "outcome": "no_action", "trigger": "schedule"}
        for i in range(1, 6)
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    mock_pool.execute = AsyncMock(return_value="INSERT 0 1")
    mc._db._pool = mock_pool

    # All vectors identical -> one cluster of 5
    identical_vec = [0.5] * 10

    with (
        patch.object(mc._store, "_embed", return_value=identical_vec),
        patch.object(mc._store, "store_memory", return_value=100),
        patch.object(mc._store, "embed_and_store", return_value=True),
    ):
        result = await mc.consolidate(min_cluster_size=5)

    assert result.memories_scanned == 5
    assert result.clusters_found == 1
    assert result.patterns_created == 1
    assert result.memories_consolidated == 5
    # Verify consolidation tracking was called for each original
    assert mock_pool.execute.call_count == 5


async def test_consolidate_tracks_in_consolidation_table():
    """Each original memory gets an entry in memory_consolidation."""
    mc = MemoryConsolidator(project="monitoring")

    mock_rows = [
        {"id": i, "summary": "same thing", "memory_type": "incident",
         "outcome": "resolved", "trigger": "health_loop"}
        for i in range(10, 15)
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    mock_pool.execute = AsyncMock(return_value="INSERT 0 1")
    mc._db._pool = mock_pool

    identical_vec = [1.0] * 10

    with (
        patch.object(mc._store, "_embed", return_value=identical_vec),
        patch.object(mc._store, "store_memory", return_value=999),
        patch.object(mc._store, "embed_and_store", return_value=True),
    ):
        _ = await mc.consolidate(min_cluster_size=5)

    # Each of the 5 originals should be tracked
    execute_calls = mock_pool.execute.call_args_list
    consolidated_ids = [call[0][1] for call in execute_calls]
    assert sorted(consolidated_ids) == list(range(10, 15))
    # All consolidated into the pattern memory #999
    pattern_ids = [call[0][2] for call in execute_calls]
    assert all(pid == 999 for pid in pattern_ids)


async def test_consolidate_handles_store_failure():
    """If store_memory returns None, the cluster is skipped."""
    mc = MemoryConsolidator(project="monitoring")

    mock_rows = [
        {"id": i, "summary": "repeat", "memory_type": "check",
         "outcome": "no_action", "trigger": "schedule"}
        for i in range(5)
    ]
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=mock_rows)
    mc._db._pool = mock_pool

    identical_vec = [1.0] * 10

    with (
        patch.object(mc._store, "_embed", return_value=identical_vec),
        patch.object(mc._store, "store_memory", return_value=None),
    ):
        result = await mc.consolidate(min_cluster_size=5)

    assert result.patterns_created == 0
    assert result.memories_consolidated == 0
