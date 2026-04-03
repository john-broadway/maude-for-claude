# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for AutonomyMetrics — per-room and fleet scoring."""

from datetime import date
from unittest.mock import AsyncMock, patch

import pytest

from maude.coordination.autonomy_metrics import (
    _DEFAULT_SCORES,
    AutonomyMetrics,
    compute_autonomy_score,
)


@pytest.fixture
def metrics():
    return AutonomyMetrics(db_host="localhost")


class FakeRecord(dict):
    """Mimics asyncpg.Record enough for dict-style access."""
    pass


# ── compute_autonomy_score ───────────────────────────────────────────


def test_autonomy_score_perfect():
    """100% resolution, 100% self-heal, 0% escalation, 0% false restart = 100."""
    score = compute_autonomy_score(1.0, 1.0, 0.0, 0.0)
    assert score == 100.0


def test_autonomy_score_zero():
    """0% resolution, 0% self-heal, 100% escalation, 100% false restart = 0."""
    score = compute_autonomy_score(0.0, 0.0, 1.0, 1.0)
    assert score == 0.0


def test_autonomy_score_mixed():
    """Hand-calculated mixed scenario."""
    # resolution=0.8, self_heal=0.5, escalation=0.2, false_restart=0.1
    # 0.40*0.8 + 0.25*0.5 + 0.20*(1-0.2) + 0.15*(1-0.1)
    # = 0.32 + 0.125 + 0.16 + 0.135 = 0.74 => 74.0
    score = compute_autonomy_score(0.8, 0.5, 0.2, 0.1)
    assert score == 74.0


def test_autonomy_score_clamps_above_100():
    """Score is clamped at 100 even with impossible inputs."""
    score = compute_autonomy_score(2.0, 2.0, -1.0, -1.0)
    assert score == 100.0


def test_autonomy_score_clamps_below_0():
    """Score is clamped at 0 even with impossible negative inputs."""
    score = compute_autonomy_score(-1.0, -1.0, 2.0, 2.0)
    assert score == 0.0


# ── room_score ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_room_score_no_pool(metrics):
    """Returns defaults when DB unavailable."""
    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=None):
        result = await metrics.room_score("monitoring")
    assert result["project"] == "monitoring"
    assert result["total_incidents"] == 0
    assert result["autonomy_score"] == 0.0


@pytest.mark.asyncio
async def test_room_score_zero_incidents(metrics):
    """Returns defaults when no incidents found."""
    counts_row = FakeRecord({
        "total_incidents": 0,
        "resolved_count": 0,
        "remediated_count": 0,
        "actionable_count": 0,
        "escalated_count": 0,
        "non_noop_count": 0,
        "false_restart_count": 0,
        "incident_type_count": 0,
    })
    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(return_value=counts_row)

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        result = await metrics.room_score("my-service")

    assert result["project"] == "my-service"
    assert result["total_incidents"] == 0
    assert result["autonomy_score"] == 0.0


@pytest.mark.asyncio
async def test_room_score_with_data(metrics):
    """Compute correct metrics from realistic mock data."""
    # 10 total incidents, 6 resolved, 3 remediated, 8 actionable,
    # 1 escalated, 9 non_noop, 2 false restarts out of 7 incident-type
    counts_row = FakeRecord({
        "total_incidents": 10,
        "resolved_count": 6,
        "remediated_count": 3,
        "actionable_count": 8,
        "escalated_count": 1,
        "non_noop_count": 9,
        "false_restart_count": 2,
        "incident_type_count": 7,
    })
    mttr_row = FakeRecord({"mttr": 120.5})

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(side_effect=[counts_row, mttr_row])

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        result = await metrics.room_score("monitoring", hours=12)

    # resolution_rate = 6/9 = 0.6667
    assert result["resolution_rate"] == round(6 / 9, 4)
    # self_heal_rate = 3/8 = 0.375
    assert result["self_heal_rate"] == 0.375
    # escalation_rate = 1/10 = 0.1
    assert result["escalation_rate"] == 0.1
    # false_restart_rate = 2/7 ≈ 0.2857
    assert result["false_restart_rate"] == round(2 / 7, 4)
    # mttr
    assert result["mttr_seconds"] == 120.5
    assert result["total_incidents"] == 10
    # autonomy score hand-calc:
    expected = compute_autonomy_score(6 / 9, 3 / 8, 1 / 10, 2 / 7)
    assert result["autonomy_score"] == expected


@pytest.mark.asyncio
async def test_room_score_null_mttr(metrics):
    """MTTR is None when no paired incidents/resolutions exist."""
    counts_row = FakeRecord({
        "total_incidents": 5,
        "resolved_count": 0,
        "remediated_count": 0,
        "actionable_count": 3,
        "escalated_count": 2,
        "non_noop_count": 3,
        "false_restart_count": 1,
        "incident_type_count": 4,
    })
    mttr_row = FakeRecord({"mttr": None})

    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(side_effect=[counts_row, mttr_row])

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        result = await metrics.room_score("redis")

    assert result["mttr_seconds"] is None


@pytest.mark.asyncio
async def test_room_score_db_exception(metrics):
    """Returns defaults on DB error."""
    mock_pool = AsyncMock()
    mock_pool.fetchrow = AsyncMock(side_effect=Exception("connection lost"))

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        result = await metrics.room_score("monitoring")

    assert result["project"] == "monitoring"
    assert result == {"project": "monitoring", **_DEFAULT_SCORES}


# ── fleet_scores ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_scores_no_pool(metrics):
    """Returns empty list when DB unavailable."""
    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=None):
        result = await metrics.fleet_scores()
    assert result == []


@pytest.mark.asyncio
async def test_fleet_scores_calls_room_score(metrics):
    """fleet_scores calls room_score for each active project."""
    projects = [FakeRecord({"project": "monitoring"}), FakeRecord({"project": "my-service"})]

    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=projects)

    monitoring_score = {"project": "monitoring", "autonomy_score": 80.0, "total_incidents": 5}
    collector_score = {"project": "my-service", "autonomy_score": 65.0, "total_incidents": 3}

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        with patch.object(
            metrics, "room_score", new_callable=AsyncMock,
            side_effect=[monitoring_score, collector_score],
        ) as mock_room_score:
            result = await metrics.fleet_scores(hours=48)

            assert len(result) == 2
            assert result[0]["project"] == "monitoring"
            assert result[1]["project"] == "my-service"
            assert mock_room_score.await_count == 2
            mock_room_score.assert_any_await("monitoring", 48)
            mock_room_score.assert_any_await("my-service", 48)


@pytest.mark.asyncio
async def test_fleet_scores_db_exception(metrics):
    """Returns empty list on DB error during project fetch."""
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=Exception("timeout"))

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        result = await metrics.fleet_scores()

    assert result == []


# ── snapshot_daily ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_snapshot_daily_upserts(metrics):
    """snapshot_daily calls room_score and executes upsert."""
    score = {
        "project": "monitoring",
        "resolution_rate": 0.75,
        "self_heal_rate": 0.5,
        "escalation_rate": 0.1,
        "false_restart_rate": 0.05,
        "mttr_seconds": 90.0,
        "autonomy_score": 78.25,
        "total_incidents": 20,
    }
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock()

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        with patch.object(metrics, "room_score", new_callable=AsyncMock, return_value=score):
            await metrics.snapshot_daily("monitoring")

    mock_pool.execute.assert_awaited_once()
    args = mock_pool.execute.call_args[0]
    # positional: SQL, project, date, rates..., score, total
    assert args[1] == "monitoring"
    assert args[2] == date.today()
    assert args[3] == 0.75   # resolution_rate
    assert args[4] == 0.5    # self_heal_rate
    assert args[5] == 0.1    # escalation_rate
    assert args[6] == 0.05   # false_restart_rate
    assert args[7] == 90.0   # mttr_seconds
    assert args[8] == 78.25  # autonomy_score
    assert args[9] == 20     # total_incidents


@pytest.mark.asyncio
async def test_snapshot_daily_no_pool(metrics):
    """snapshot_daily is a no-op when DB unavailable."""
    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=None):
        await metrics.snapshot_daily("monitoring")  # should not raise


@pytest.mark.asyncio
async def test_snapshot_daily_db_exception(metrics):
    """snapshot_daily handles DB errors gracefully."""
    score = {"project": "monitoring", **_DEFAULT_SCORES}
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(side_effect=Exception("unique violation"))

    with patch.object(metrics, "_ensure_pool", new_callable=AsyncMock, return_value=mock_pool):
        with patch.object(metrics, "room_score", new_callable=AsyncMock, return_value=score):
            await metrics.snapshot_daily("monitoring")  # should not raise


# ── close ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_with_pool():
    """close() closes the pool and sets it to None."""
    m = AutonomyMetrics(db_host="localhost")
    mock_pool = AsyncMock()
    m._db._pool = mock_pool

    await m.close()
    mock_pool.close.assert_awaited_once()
    assert m._db._pool is None


@pytest.mark.asyncio
async def test_close_without_pool():
    """close() is safe when pool is None."""
    m = AutonomyMetrics(db_host="localhost")
    await m.close()  # should not raise
