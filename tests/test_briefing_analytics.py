"""Tests for BriefingAnalytics — pattern detection for briefing enrichment.

Version: 1.0.0
Created: 2026-04-01 00:00 MST
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from maude.coordination.briefing_analytics import (
    _ESCALATION_RATE_THRESHOLD,
    _MIN_INCIDENTS_FOR_REPEAT,
    _MIN_RESTARTS_FOR_LOOP,
    _TRENDING_THRESHOLD,
    BriefingAnalytics,
)


@pytest.fixture
def analytics() -> BriefingAnalytics:
    return BriefingAnalytics(db_host="fake")


# ── repeat offenders ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_repeat_offenders_returns_insight(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {
            "project": "grafana",
            "incident_count": 5,
            "failed_count": 2,
            "escalated_count": 1,
            "remediated_count": 1,
        },
    ]

    result = await analytics._repeat_offenders(pool, 60)

    assert len(result) == 1
    assert "grafana" in result[0]
    assert "5 incidents" in result[0]
    assert "2 failed" in result[0]
    assert "1 escalated" in result[0]
    assert "1 self-healed" in result[0]


@pytest.mark.asyncio
async def test_repeat_offenders_empty_when_no_rows(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = []

    result = await analytics._repeat_offenders(pool, 60)

    assert result == []


# ── restart loops ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_restart_loop_detected(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "redis", "restart_count": 4},
    ]

    result = await analytics._restart_loops(pool, 60)

    assert len(result) == 1
    assert "redis" in result[0]
    assert "4 restarts" in result[0]
    assert "restart loop" in result[0]


# ── escalation spikes ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_escalation_spike_flagged(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "authentik", "total": 10, "escalated": 5},
    ]

    result = await analytics._escalation_spikes(pool, 60)

    assert len(result) == 1
    assert "authentik" in result[0]
    assert "5/10" in result[0]
    assert "50%" in result[0]


@pytest.mark.asyncio
async def test_escalation_below_threshold_skipped(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "dns", "total": 10, "escalated": 1},
    ]

    result = await analytics._escalation_spikes(pool, 60)

    assert result == []


# ── trending rooms ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_trending_up_detected(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "gpu-node-1", "current_count": 6, "prior_count": 2},
    ]

    result = await analytics._trending_rooms(pool, 60)

    assert len(result) == 1
    assert "gpu-node-1" in result[0]
    assert "trending up" in result[0]
    assert "+200%" in result[0]


@pytest.mark.asyncio
async def test_new_issues_detected(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "example-ehs", "current_count": 4, "prior_count": 0},
    ]

    result = await analytics._trending_rooms(pool, 60)

    assert len(result) == 1
    assert "example-ehs" in result[0]
    assert "new issues" in result[0]


@pytest.mark.asyncio
async def test_stable_room_no_trend(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.return_value = [
        {"project": "postgresql", "current_count": 3, "prior_count": 3},
    ]

    result = await analytics._trending_rooms(pool, 60)

    assert result == []


# ── full analyze ────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_analyze_returns_fallback_when_no_pool(analytics: BriefingAnalytics) -> None:
    with patch.object(analytics._db, "get", return_value=None):
        result = await analytics.analyze(60)

    assert len(result) == 1
    assert "unavailable" in result[0]


@pytest.mark.asyncio
async def test_analyze_aggregates_all_insights(analytics: BriefingAnalytics) -> None:
    pool = AsyncMock()
    pool.fetch.side_effect = [
        [
            {
                "project": "grafana",
                "incident_count": 5,
                "failed_count": 2,
                "escalated_count": 0,
                "remediated_count": 1,
            }
        ],
        [],  # restart loops
        [],  # escalation spikes
        [],  # trending
    ]

    with patch.object(analytics._db, "get", return_value=pool):
        result = await analytics.analyze(60)

    assert len(result) == 1
    assert "grafana" in result[0]


# ── threshold constants are importable ──────────────────────────────


def test_thresholds_are_sensible() -> None:
    assert _MIN_INCIDENTS_FOR_REPEAT >= 2
    assert _MIN_RESTARTS_FOR_LOOP >= 2
    assert 1.0 < _TRENDING_THRESHOLD < 5.0
    assert 0.0 < _ESCALATION_RATE_THRESHOLD < 1.0
