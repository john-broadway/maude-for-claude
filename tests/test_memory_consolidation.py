"""Tests for MemoryConsolidator — cluster vault memories and extract patterns.

Version: 1.0.0
Created: 2026-04-01 01:05 MST
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.memory.consolidation import (
    MIN_CLUSTER_SIZE,
    SIMILARITY_THRESHOLD,
    MemoryConsolidator,
    _cosine_similarity,
    _extract_resolution,
    _extract_source_ids,
    _extract_trigger,
    _find_overlapping_pattern,
    _normalize_dates,
)

# ── cosine similarity ──────────────────────────────────────────────


def test_cosine_identical_vectors() -> None:
    assert _cosine_similarity([1.0, 0.0, 0.0], [1.0, 0.0, 0.0]) == pytest.approx(1.0)


def test_cosine_orthogonal_vectors() -> None:
    assert _cosine_similarity([1.0, 0.0], [0.0, 1.0]) == pytest.approx(0.0)


def test_cosine_opposite_vectors() -> None:
    assert _cosine_similarity([1.0, 0.0], [-1.0, 0.0]) == pytest.approx(-1.0)


def test_cosine_zero_vector_returns_zero() -> None:
    assert _cosine_similarity([0.0, 0.0], [1.0, 1.0]) == 0.0


def test_cosine_similar_vectors() -> None:
    sim = _cosine_similarity([1.0, 0.9, 0.8], [1.0, 0.85, 0.75])
    assert sim > 0.99  # Very similar


# ── clustering ─────────────────────────────────────────────────────


def _make_point(
    point_id: int,
    vector: list[float],
    summary: str = "",
    pg_id: int | None = None,
    outcome: str = "resolved",
) -> dict:
    return {
        "id": point_id,
        "vector": vector,
        "pg_id": pg_id or point_id,
        "summary": summary,
        "outcome": outcome,
        "memory_type": "incident",
        "created_at": "2026-03-01",
    }


def test_cluster_similar_points_together() -> None:
    consolidator = MemoryConsolidator()
    points = [
        _make_point(1, [1.0, 0.0, 0.0]),
        _make_point(2, [0.99, 0.05, 0.0]),  # Very similar to 1
        _make_point(3, [0.98, 0.1, 0.0]),  # Very similar to 1
        _make_point(4, [0.0, 0.0, 1.0]),  # Different direction
    ]

    clusters = consolidator._cluster_points(points)

    # Points 1-3 should cluster together, point 4 separate
    assert len(clusters) == 2
    big_cluster = max(clusters, key=len)
    assert len(big_cluster) == 3


def test_cluster_skips_empty_vectors() -> None:
    consolidator = MemoryConsolidator()
    points = [
        _make_point(1, [1.0, 0.0]),
        _make_point(2, []),  # No vector
        _make_point(3, [1.0, 0.0]),
    ]

    clusters = consolidator._cluster_points(points)
    total_points = sum(len(c) for c in clusters)
    assert total_points == 2  # Only 2 points with vectors


def test_cluster_all_dissimilar_creates_singletons() -> None:
    consolidator = MemoryConsolidator()
    points = [
        _make_point(1, [1.0, 0.0, 0.0]),
        _make_point(2, [0.0, 1.0, 0.0]),
        _make_point(3, [0.0, 0.0, 1.0]),
    ]

    clusters = consolidator._cluster_points(points)
    assert len(clusters) == 3
    assert all(len(c) == 1 for c in clusters)


# ── extract helpers ────────────────────────────────────────────────


def test_extract_trigger_uses_common_words() -> None:
    cluster = [
        _make_point(1, [], summary="PostgreSQL connection timeout on grafana datasource"),
        _make_point(2, [], summary="PostgreSQL connection refused grafana dashboard"),
        _make_point(3, [], summary="PostgreSQL connection error grafana health check"),
    ]

    trigger = _extract_trigger(cluster)

    # "postgresql", "connection", "grafana" should be the top words
    assert "postgresql" in trigger.lower()
    assert "connection" in trigger.lower()
    assert "grafana" in trigger.lower()


def test_extract_trigger_falls_back_to_first_summary() -> None:
    cluster = [
        _make_point(1, [], summary="hi"),  # Only short words
    ]

    trigger = _extract_trigger(cluster)
    assert trigger == "hi"


def test_extract_resolution_picks_most_common() -> None:
    cluster = [
        _make_point(1, [], outcome="resolved"),
        _make_point(2, [], outcome="remediated"),
        _make_point(3, [], outcome="resolved"),
    ]

    assert _extract_resolution(cluster) == "resolved"


def test_extract_resolution_empty_outcomes() -> None:
    cluster = [
        _make_point(1, [], outcome=""),
        _make_point(2, [], outcome=""),
    ]

    assert _extract_resolution(cluster) == ""


def test_extract_source_ids() -> None:
    cluster = [
        _make_point(1, [], pg_id=100),
        _make_point(2, [], pg_id=200),
        _make_point(3, [], pg_id=None),
    ]

    # pg_id=None from _make_point defaults to point_id (3), so it's still an int
    ids = _extract_source_ids(cluster)
    assert 100 in ids
    assert 200 in ids


# ── overlap detection ──────────────────────────────────────────────


def _make_record(row_id: int, source_ids: list[int], frequency: int = 1) -> MagicMock:
    """Fake asyncpg.Record."""
    record = MagicMock()
    record.__getitem__ = lambda self, key: {
        "id": row_id,
        "source_memory_ids": source_ids,
        "frequency": frequency,
    }[key]
    return record


def test_overlap_finds_matching_pattern() -> None:
    existing = [_make_record(1, [10, 20, 30, 40])]
    source_ids = {20, 30, 50}  # 2 out of 4 = 50%, 2 out of 3 = 67%

    match = _find_overlapping_pattern(source_ids, existing)

    assert match is not None
    assert match["id"] == 1


def test_overlap_returns_none_when_no_match() -> None:
    existing = [_make_record(1, [10, 20, 30, 40])]
    source_ids = {100, 200}  # Zero overlap

    match = _find_overlapping_pattern(source_ids, existing)
    assert match is None


def test_overlap_returns_none_for_empty_source_ids() -> None:
    existing = [_make_record(1, [10, 20])]
    match = _find_overlapping_pattern(set(), existing)
    assert match is None


def test_overlap_handles_empty_existing_ids() -> None:
    existing = [_make_record(1, [])]
    source_ids = {10, 20}

    match = _find_overlapping_pattern(source_ids, existing)
    assert match is None


# ── consolidate_project ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_consolidate_project_skips_when_too_few_points() -> None:
    consolidator = MemoryConsolidator()

    fake_qdrant = AsyncMock()
    fake_qdrant.scroll = AsyncMock(return_value=([], None))
    consolidator._qdrant = fake_qdrant
    consolidator._conn = AsyncMock()

    stats = await consolidator.consolidate_project("grafana")

    assert stats["patterns_found"] == 0
    assert stats["new"] == 0


@pytest.mark.asyncio
async def test_consolidate_project_creates_new_pattern() -> None:
    consolidator = MemoryConsolidator(min_hours=0, min_memories=0)

    # 3 similar points = 1 cluster above MIN_CLUSTER_SIZE
    vec = [1.0, 0.0, 0.0]
    fake_points = [
        MagicMock(
            id=i,
            vector=vec,
            payload={
                "project": "grafana",
                "pg_id": i,
                "summary": f"PostgreSQL timeout #{i}",
                "outcome": "resolved",
                "memory_type": "incident",
                "created_at": "2026-03-01",
            },
        )
        for i in range(1, 4)
    ]

    fake_qdrant = AsyncMock()
    fake_qdrant.scroll = AsyncMock(return_value=(fake_points, None))
    consolidator._qdrant = fake_qdrant

    fake_conn = AsyncMock()
    fake_conn.fetch = AsyncMock(return_value=[])  # No existing patterns
    fake_conn.fetchval = AsyncMock(return_value=1)  # New pattern ID
    fake_conn.is_closed = MagicMock(return_value=False)
    consolidator._conn = fake_conn

    stats = await consolidator.consolidate_project("grafana")

    assert stats["patterns_found"] == 1
    assert stats["new"] == 1
    assert stats["updated"] == 0


@pytest.mark.asyncio
async def test_consolidate_all_handles_failures_gracefully() -> None:
    consolidator = MemoryConsolidator()

    fake_qdrant = AsyncMock()
    # Return 2 projects
    points_a = [
        MagicMock(id=1, payload={"project": "grafana"}),
        MagicMock(id=2, payload={"project": "redis"}),
    ]
    fake_qdrant.scroll = AsyncMock(return_value=(points_a, None))
    consolidator._qdrant = fake_qdrant

    # Make consolidate_project fail for both (too few points after scroll)
    with patch.object(
        consolidator,
        "consolidate_project",
        side_effect=[
            {"patterns_found": 2, "new": 1, "updated": 1},
            RuntimeError("Qdrant down"),
        ],
    ):
        results = await consolidator.consolidate_all()

    assert "grafana" in results
    assert results["grafana"]["new"] == 1
    assert "redis" in results
    assert results["redis"]["patterns_found"] == 0  # Failure fallback


# ── close ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_cleans_up_connections() -> None:
    consolidator = MemoryConsolidator()
    fake_conn = AsyncMock()
    fake_conn.is_closed = MagicMock(return_value=False)
    fake_qdrant = AsyncMock()
    consolidator._conn = fake_conn
    consolidator._qdrant = fake_qdrant

    await consolidator.close()

    fake_conn.close.assert_awaited_once()
    fake_qdrant.close.assert_awaited_once()
    assert consolidator._conn is None
    assert consolidator._qdrant is None


@pytest.mark.asyncio
async def test_close_noop_when_not_connected() -> None:
    consolidator = MemoryConsolidator()
    await consolidator.close()  # Should not raise


# ── constants sanity ───────────────────────────────────────────────


def test_thresholds_are_sensible() -> None:
    assert 0.5 < SIMILARITY_THRESHOLD < 1.0
    assert MIN_CLUSTER_SIZE >= 2


# ── Three-gate consolidation pipeline tests ──────────────────────────


def test_time_gate_passes_on_first_run() -> None:
    """Time gate passes when project has never been consolidated."""
    consolidator = MemoryConsolidator(min_hours=24)
    assert consolidator._check_time_gate("grafana") is True


def test_time_gate_blocks_recent_consolidation() -> None:
    """Time gate blocks if last consolidation was too recent."""
    import time

    consolidator = MemoryConsolidator(min_hours=24)
    consolidator._last_consolidated["grafana"] = time.monotonic()
    assert consolidator._check_time_gate("grafana") is False


def test_time_gate_passes_after_enough_time() -> None:
    """Time gate passes after min_hours have elapsed."""
    import time

    consolidator = MemoryConsolidator(min_hours=0.001)  # ~3.6 seconds
    # Set last consolidation far in the past
    consolidator._last_consolidated["grafana"] = time.monotonic() - 100
    assert consolidator._check_time_gate("grafana") is True


@pytest.mark.asyncio
async def test_consolidate_project_gated_returns_gated_flag() -> None:
    """Gated consolidation returns gated=1 in stats."""
    import time

    consolidator = MemoryConsolidator(min_hours=24)
    # Simulate recent consolidation
    consolidator._last_consolidated["grafana"] = time.monotonic()

    stats = await consolidator.consolidate_project("grafana")
    assert stats.get("gated") == 1
    assert stats["patterns_found"] == 0


@pytest.mark.asyncio
async def test_consolidate_project_records_timestamp() -> None:
    """Successful consolidation records last_consolidated timestamp."""
    consolidator = MemoryConsolidator(min_hours=0, min_memories=0)

    fake_qdrant = AsyncMock()
    fake_qdrant.scroll = AsyncMock(return_value=([], None))
    consolidator._qdrant = fake_qdrant

    fake_conn = AsyncMock()
    fake_conn.is_closed = MagicMock(return_value=False)
    consolidator._conn = fake_conn

    await consolidator.consolidate_project("grafana")

    assert "grafana" in consolidator._last_consolidated
    assert consolidator._last_consolidated["grafana"] > 0


def test_gate_defaults() -> None:
    """Default gate thresholds are sensible."""
    from maude.memory.consolidation import DEFAULT_MIN_HOURS, DEFAULT_MIN_MEMORIES

    assert DEFAULT_MIN_HOURS == 24.0
    assert DEFAULT_MIN_MEMORIES == 20


# ── Date normalization ────────────────────────────────────────────────


def test_normalize_dates_today() -> None:
    from datetime import datetime, timezone

    result = _normalize_dates("Error happened today in grafana")
    today_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    assert today_iso in result
    assert "today" not in result.lower()


def test_normalize_dates_yesterday() -> None:
    from datetime import datetime, timedelta, timezone

    result = _normalize_dates("Incident yesterday caused outage")
    yesterday_iso = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
    assert yesterday_iso in result
    assert "yesterday" not in result.lower()


def test_normalize_dates_last_week() -> None:
    result = _normalize_dates("Fixed last week")
    assert "last week" not in result.lower()
    # Should contain a date
    assert "-" in result  # ISO date contains dashes


def test_normalize_dates_no_relative_dates() -> None:
    text = "Service restarted on 2026-03-15"
    assert _normalize_dates(text) == text


def test_normalize_dates_empty() -> None:
    assert _normalize_dates("") == ""


# ── Contradiction detection ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_deprecate_contradicted_detects_different_resolution() -> None:
    """Patterns with same trigger but different resolution are deprecated."""
    consolidator = MemoryConsolidator()
    fake_conn = AsyncMock()
    fake_conn.execute = AsyncMock()

    existing = [
        {
            "id": 10,
            "pattern_type": "recurring",
            "trigger_pattern": "service | restart | failed | grafana",
            "resolution_pattern": "resolved",
            "source_memory_ids": [1, 2, 3],
            "frequency": 3,
        }
    ]

    # Same trigger keywords, different resolution
    deprecated = await consolidator._deprecate_contradicted(
        fake_conn,
        existing,
        "service | restart | failed | grafana",
        "escalated",
    )

    assert deprecated == 1
    fake_conn.execute.assert_awaited_once()


@pytest.mark.asyncio
async def test_deprecate_contradicted_ignores_same_resolution() -> None:
    """Patterns with same trigger AND same resolution are not deprecated."""
    consolidator = MemoryConsolidator()
    fake_conn = AsyncMock()

    existing = [
        {
            "id": 10,
            "pattern_type": "recurring",
            "trigger_pattern": "disk | full | grafana",
            "resolution_pattern": "resolved",
            "source_memory_ids": [1, 2],
            "frequency": 2,
        }
    ]

    deprecated = await consolidator._deprecate_contradicted(
        fake_conn, existing, "disk | full | grafana", "resolved"
    )

    assert deprecated == 0
    fake_conn.execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_deprecate_contradicted_skips_already_deprecated() -> None:
    """Already deprecated patterns are not deprecated again."""
    consolidator = MemoryConsolidator()
    fake_conn = AsyncMock()

    existing = [
        {
            "id": 10,
            "pattern_type": "deprecated",
            "trigger_pattern": "disk | full",
            "resolution_pattern": "resolved",
            "source_memory_ids": [1, 2],
            "frequency": 2,
        }
    ]

    deprecated = await consolidator._deprecate_contradicted(
        fake_conn, existing, "disk | full", "escalated"
    )

    assert deprecated == 0


@pytest.mark.asyncio
async def test_deprecate_contradicted_low_trigger_overlap() -> None:
    """Patterns with <50% trigger overlap are not contradictions."""
    consolidator = MemoryConsolidator()
    fake_conn = AsyncMock()

    existing = [
        {
            "id": 10,
            "pattern_type": "recurring",
            "trigger_pattern": "disk | full | grafana | space",
            "resolution_pattern": "resolved",
            "source_memory_ids": [1, 2],
            "frequency": 2,
        }
    ]

    # Only 1 of 4 keywords overlap (25% < 50%)
    deprecated = await consolidator._deprecate_contradicted(
        fake_conn, existing, "redis | memory | connection | disk", "failed"
    )

    assert deprecated == 0


# ── Type-aware filtering ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_consolidation_filters_non_consolidatable_types() -> None:
    """Points with consolidate='none' policy are filtered before clustering."""
    consolidator = MemoryConsolidator(min_hours=0, min_memories=0)

    # Create points: some with consolidatable types, some not
    vec = [1.0] * 10
    points = [
        # pattern type has consolidate="none" → should be filtered
        MagicMock(
            id=f"p{i}",
            payload={"project": "grafana", "summary": f"pattern {i}", "memory_type": "pattern"},
            vector=vec,
        )
        for i in range(5)
    ] + [
        # incident type has consolidate="similarity" → should be kept
        MagicMock(
            id=f"i{i}",
            payload={
                "project": "grafana",
                "summary": f"incident {i}",
                "memory_type": "incident",
                "outcome": "resolved",
            },
            vector=vec,
        )
        for i in range(2)
    ]

    fake_qdrant = AsyncMock()
    fake_qdrant.scroll = AsyncMock(return_value=(points, None))
    consolidator._qdrant = fake_qdrant

    fake_conn = AsyncMock()
    fake_conn.is_closed = MagicMock(return_value=False)
    fake_conn.fetchval = AsyncMock(return_value=True)  # lock acquired
    fake_conn.fetch = AsyncMock(return_value=[])  # no existing patterns
    consolidator._conn = fake_conn

    stats = await consolidator.consolidate_project("grafana")

    # Only 2 incident points pass the type filter — below MIN_CLUSTER_SIZE (3)
    # So no patterns should be created
    assert stats["new"] == 0
