"""Edge traps — tests that catch real production bugs, not just assert happy paths.

Version: 1.0.0
Created: 2026-04-01 01:40 MST
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)

These tests probe failure modes that have bitten (or could bite) production:
- NULL values from PostgreSQL where code expects defaults
- Concurrent access races
- Negative/extreme parameter values
- Clock skew in event timestamps
- Double-close on resources
- Malformed data from upstream
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination.briefing import BriefingGenerator
from maude.coordination.correlation import CorrelationEngine
from maude.healing.dependencies import DependencyGraph
from maude.memory.consolidation import _cosine_similarity

# ── NULL fields from PostgreSQL ────────────────────────────────────
# PG returns NULL (None) for missing columns, not KeyError.
# Code using dict.get("key", 0) is safe, but s["key"] or
# s.get("key") without default would crash.


@pytest.mark.asyncio
async def test_briefing_survives_null_fields_in_summary():
    """PG returns None for failed/escalated instead of 0."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = [
        {
            "project": "example-scada",
            "total_runs": 5,
            "resolved": None,  # NULL from PG
            "failed": None,  # NULL from PG
            "escalated": None,  # NULL from PG
            "no_action": None,
        },
    ]
    memory.recent_incidents.return_value = []
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    # Should not raise TypeError: '>' not supported between NoneType and int
    output = await gen.generate()
    assert "Coordinator Briefing" in output


@pytest.mark.asyncio
async def test_briefing_survives_missing_project_key():
    """What if a summary row has no 'project' key at all?"""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = [
        {"total_runs": 5, "resolved": 2, "failed": 0, "escalated": 0},
    ]
    memory.recent_incidents.return_value = []
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    # KeyError on s["project"] would crash
    try:
        await gen.generate()
    except KeyError as e:
        pytest.fail(f"Briefing crashed on missing key: {e}")


@pytest.mark.asyncio
async def test_room_status_null_remediated():
    """Room status grid with remediated=None shouldn't crash."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = [
        {
            "project": "postgresql",
            "total_runs": 5,
            "resolved": 3,
            "failed": 0,
            "escalated": 0,
            "no_action": 2,
            "remediated": None,  # NULL
        },
    ]

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    try:
        await gen.room_status()
    except TypeError as e:
        pytest.fail(f"Room status crashed on None remediated: {e}")


# ── Negative / extreme parameters ──────────────────────────────────


@pytest.mark.asyncio
async def test_briefing_with_zero_minutes():
    """minutes=0 is a valid edge — 'show me nothing'."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = []
    memory.recent_incidents.return_value = []
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    output = await gen.generate(minutes=0)
    assert "Coordinator Briefing (last 0 min)" in output


@pytest.mark.asyncio
async def test_briefing_with_huge_minutes():
    """minutes=999999 — shouldn't OOM or timeout in template logic."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = []
    memory.recent_incidents.return_value = []
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    output = await gen.generate(minutes=999999)
    assert "999999" in output


# ── Correlation engine edge cases ──────────────────────────────────


def test_correlation_with_future_timestamps():
    """Events with future timestamps shouldn't break correlation."""
    deps = MagicMock(spec=DependencyGraph)
    deps.depended_by.return_value = ["example-scada", "grafana", "panel"]
    deps.depends_on.return_value = []
    deps.all_rooms = ["postgresql", "example-scada", "grafana", "panel"]

    engine = CorrelationEngine(deps)
    future = datetime.now() + timedelta(hours=1)

    engine.record_event("postgresql", "unhealthy", timestamp=future)
    engine.record_event("example-scada", "unhealthy", timestamp=future + timedelta(seconds=10))
    engine.record_event("grafana", "unhealthy", timestamp=future + timedelta(seconds=20))

    # Should still detect correlation even with future timestamps
    result = engine.check_correlation("postgresql")
    assert result is not None
    assert result.root_room == "postgresql"


def test_correlation_events_out_of_order():
    """Events arriving out of chronological order."""
    deps = MagicMock(spec=DependencyGraph)
    deps.depended_by.return_value = ["example-scada", "grafana"]
    deps.depends_on.return_value = []
    deps.all_rooms = ["postgresql", "example-scada", "grafana"]

    engine = CorrelationEngine(deps)
    now = datetime.now()

    # Events arrive: grafana first, then postgresql, then example-scada
    # But timestamps show postgresql was first
    engine.record_event("grafana", "unhealthy", timestamp=now + timedelta(seconds=30))
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("example-scada", "unhealthy", timestamp=now + timedelta(seconds=15))

    result = engine.check_correlation("postgresql")
    assert result is not None


def test_correlation_empty_dependency_graph():
    """Room with no dependents produces no correlation."""
    deps = MagicMock(spec=DependencyGraph)
    deps.depended_by.return_value = []
    deps.depends_on.return_value = []
    deps.all_rooms = ["standalone"]

    engine = CorrelationEngine(deps)
    engine.record_event("standalone", "unhealthy")

    result = engine.check_correlation("standalone")
    assert result is None


def test_correlation_score_with_single_room_fleet():
    """Fleet with 1 room: count_factor divides by total_rooms."""
    deps = MagicMock(spec=DependencyGraph)
    deps.depended_by.return_value = ["only-child"]
    deps.depends_on.return_value = []
    deps.all_rooms = ["parent"]  # Only 1 room total

    engine = CorrelationEngine(deps)
    now = datetime.now()
    engine.record_event("parent", "unhealthy", timestamp=now)
    # Need 2+ downstream to trigger, but only 1 exists
    engine.record_event("only-child", "unhealthy", timestamp=now)

    # 1 downstream < MIN_DOWNSTREAM (2), so no correlation
    result = engine.check_correlation("parent")
    assert result is None


# ── Cosine similarity edge cases ───────────────────────────────────


def test_cosine_empty_vectors():
    """Empty vectors shouldn't crash."""
    assert _cosine_similarity([], []) == 0.0


def test_cosine_mismatched_lengths():
    """Vectors of different lengths — zip truncates silently."""
    # This is a real bug risk: if embeddings have different dimensions
    result = _cosine_similarity([1.0, 0.0, 0.0], [1.0, 0.0])
    # zip stops at shorter, so it's dot(1*1 + 0*0) / (norm_3d * norm_2d)
    assert isinstance(result, float)
    assert result != 0.0  # Not zero — partial similarity computed


def test_cosine_very_large_vectors():
    """1024-dim vectors (real embedding size) shouldn't be slow."""
    import time

    a = [0.01 * i for i in range(1024)]
    b = [0.01 * (1024 - i) for i in range(1024)]

    start = time.monotonic()
    result = _cosine_similarity(a, b)
    elapsed = time.monotonic() - start

    assert isinstance(result, float)
    assert elapsed < 0.1  # Should be sub-millisecond


# ── LazyPool double-close ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_lazy_pool_double_close():
    """Closing a pool twice shouldn't crash."""
    from maude.db.pool import LazyPool

    fake_pool = AsyncMock()
    fake_pool.close = AsyncMock()

    with patch(
        "maude.db.pool.asyncpg.create_pool",
        new_callable=AsyncMock,
        return_value=fake_pool,
    ):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            await lp.get()

    await lp.close()
    await lp.close()  # Second close should be noop, not crash
    assert lp._pool is None


# ── Concurrent briefing generation ─────────────────────────────────


@pytest.mark.asyncio
async def test_concurrent_briefings_dont_corrupt():
    """Two briefings generated simultaneously with different scopes."""
    memory = AsyncMock()

    call_count = 0

    async def slow_summary(minutes):
        nonlocal call_count
        call_count += 1
        await asyncio.sleep(0.05)
        return [
            {"project": "dns", "total_runs": 3, "resolved": 3, "failed": 0, "escalated": 0},
        ]

    memory.all_rooms_summary = slow_summary
    memory.recent_incidents = AsyncMock(return_value=[])
    memory.recent_escalations = AsyncMock(return_value=[])
    memory.recent_restarts = AsyncMock(return_value=[])
    memory.recent_remediations = AsyncMock(return_value=[])

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())

    results = await asyncio.gather(
        gen.generate(minutes=60),
        gen.generate(minutes=120),
    )

    assert len(results) == 2
    assert "last 60 min" in results[0]
    assert "last 120 min" in results[1]
    assert call_count == 2  # Both ran, neither was skipped


# ── Malformed incident data ────────────────────────────────────────


@pytest.mark.asyncio
async def test_briefing_with_empty_string_timestamp():
    """Incident with empty string timestamp shouldn't crash format_time."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = []
    memory.recent_incidents.return_value = [
        {"project": "dns", "summary": "test", "outcome": "failed", "created_at": ""},
    ]
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    output = await gen.generate()
    # Empty timestamp should produce "??:??" not crash
    assert "dns" in output


@pytest.mark.asyncio
async def test_briefing_with_none_summary():
    """Incident with None summary shouldn't crash."""
    memory = AsyncMock()
    memory.all_rooms_summary.return_value = []
    memory.recent_incidents.return_value = [
        {
            "project": "dns",
            "summary": None,
            "outcome": "failed",
            "created_at": "2026-02-01T10:00:00",
        },
    ]
    memory.recent_escalations.return_value = []
    memory.recent_restarts.return_value = []
    memory.recent_remediations.return_value = []

    gen = BriefingGenerator(memory=memory, deps=DependencyGraph())
    try:
        await gen.generate()
    except TypeError as e:
        pytest.fail(f"Briefing crashed on None summary: {e}")
