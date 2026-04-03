# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for CorrelationEngine — cross-room incident correlation."""

from collections import deque
from datetime import datetime, timedelta
from unittest.mock import MagicMock

import pytest

from maude.coordination.correlation import CorrelatedIncident, CorrelationEngine


def _make_graph() -> MagicMock:
    """Mock DependencyGraph: postgresql -> monitoring, collector, scada."""
    graph = MagicMock()

    deps_map = {
        "postgresql": [],
        "monitoring": ["postgresql"],
        "my-service": ["postgresql"],
        "scada": ["postgresql"],
    }
    reverse_map = {
        "postgresql": ["monitoring", "my-service", "scada"],
        "monitoring": [],
        "my-service": [],
        "scada": [],
    }

    graph.depends_on = lambda room: list(deps_map.get(room, []))
    graph.depended_by = lambda room: list(reverse_map.get(room, []))
    graph.all_rooms = sorted(deps_map.keys())
    graph.affected_by = lambda room: sorted(r for r in deps_map if room in deps_map.get(r, []))

    return graph


@pytest.fixture
def engine() -> CorrelationEngine:
    return CorrelationEngine(_make_graph())


@pytest.fixture
def now() -> datetime:
    # Must be recent — CorrelationEngine purges events older than 30 min
    # from wall-clock time during record_event.
    return datetime.now()


# ── Recording events ──────────────────────────────────────────────


def test_record_event_stores_event(engine: CorrelationEngine, now: datetime):
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    # Internal state: event should be in the buffer
    assert "postgresql" in engine._events
    assert len(engine._events["postgresql"]) == 1
    assert engine._events["postgresql"][0].room == "postgresql"
    assert engine._events["postgresql"][0].event_type == "unhealthy"


def test_record_event_default_timestamp(engine: CorrelationEngine):
    engine.record_event("monitoring", "unhealthy")
    assert len(engine._events["monitoring"]) == 1
    # Timestamp should be close to now
    delta = abs((datetime.now() - engine._events["monitoring"][0].timestamp).total_seconds())
    assert delta < 2


def test_record_multiple_events(engine: CorrelationEngine, now: datetime):
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("postgresql", "restart", timestamp=now + timedelta(seconds=30))
    assert len(engine._events["postgresql"]) == 2


# ── Correlation detection: downstream ─────────────────────────────


def test_correlation_root_with_downstream(engine: CorrelationEngine, now: datetime):
    """postgresql unhealthy + 2 downstream rooms within 5 min -> correlation."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(minutes=1))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(minutes=2))

    result = engine.check_correlation("postgresql")
    assert result is not None
    assert isinstance(result, CorrelatedIncident)
    assert result.root_room == "postgresql"
    assert "monitoring" in result.affected_rooms
    assert "my-service" in result.affected_rooms
    assert 0.0 < result.correlation_score <= 1.0
    assert result.resolved is False


def test_correlation_root_with_all_downstream(engine: CorrelationEngine, now: datetime):
    """All 3 downstream rooms affected — higher score."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(seconds=30))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(seconds=45))
    engine.record_event("scada", "unhealthy", timestamp=now + timedelta(seconds=60))

    result = engine.check_correlation("postgresql")
    assert result is not None
    assert len(result.affected_rooms) == 3
    assert result.correlation_score > 0.5


def test_no_correlation_single_downstream(engine: CorrelationEngine, now: datetime):
    """Only 1 downstream room affected — below threshold, no correlation."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(minutes=1))

    result = engine.check_correlation("postgresql")
    assert result is None


def test_no_correlation_outside_time_window(engine: CorrelationEngine, now: datetime):
    """Events >5 min apart should not correlate."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(minutes=10))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(minutes=10))

    result = engine.check_correlation("postgresql")
    assert result is None


def test_no_correlation_no_events(engine: CorrelationEngine):
    """No events recorded — no correlation."""
    result = engine.check_correlation("postgresql")
    assert result is None


# ── Upstream root cause detection ─────────────────────────────────


def test_upstream_root_cause(engine: CorrelationEngine, now: datetime):
    """monitoring reports unhealthy, but postgresql (upstream) is root cause."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(minutes=1))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(minutes=2))

    # Check from monitoring's perspective — should find postgresql as root
    result = engine.check_correlation("monitoring")
    assert result is not None
    assert result.root_room == "postgresql"
    assert "monitoring" in result.affected_rooms
    assert "my-service" in result.affected_rooms


def test_upstream_no_correlation_when_upstream_healthy(engine: CorrelationEngine, now: datetime):
    """monitoring is unhealthy but postgresql is fine — no upstream correlation."""
    engine.record_event("monitoring", "unhealthy", timestamp=now)

    result = engine.check_correlation("monitoring")
    assert result is None


def test_upstream_no_correlation_when_upstream_too_old(engine: CorrelationEngine, now: datetime):
    """Upstream event is too old to correlate."""
    engine.record_event("postgresql", "unhealthy", timestamp=now - timedelta(minutes=10))
    engine.record_event("monitoring", "unhealthy", timestamp=now)
    engine.record_event("my-service", "unhealthy", timestamp=now)

    result = engine.check_correlation("monitoring")
    assert result is None


# ── recent_correlations ──────────────────────────────────────────


def test_recent_correlations_empty(engine: CorrelationEngine):
    assert engine.recent_correlations() == []


def test_recent_correlations_sorted_by_timestamp(engine: CorrelationEngine, now: datetime):
    """Multiple incidents should be returned newest first."""
    # First incident
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(seconds=30))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(seconds=60))
    engine.check_correlation("postgresql")

    # Second incident (later)
    later = now + timedelta(minutes=10)
    engine.record_event("postgresql", "restart", timestamp=later)
    engine.record_event("monitoring", "restart", timestamp=later + timedelta(seconds=30))
    engine.record_event("my-service", "restart", timestamp=later + timedelta(seconds=60))
    engine.check_correlation("postgresql")

    results = engine.recent_correlations()
    assert len(results) == 2
    assert results[0].timestamp > results[1].timestamp


def test_recent_correlations_respects_limit(engine: CorrelationEngine, now: datetime):
    """Limit parameter should cap the number of results."""
    for i in range(5):
        t = now + timedelta(minutes=i * 10)
        engine.record_event("postgresql", "unhealthy", timestamp=t)
        engine.record_event("monitoring", "unhealthy", timestamp=t + timedelta(seconds=30))
        engine.record_event("my-service", "unhealthy", timestamp=t + timedelta(seconds=60))
        engine.check_correlation("postgresql")

    results = engine.recent_correlations(limit=2)
    assert len(results) == 2


# ── Ring buffer cleanup ──────────────────────────────────────────


def test_cleanup_removes_old_events(engine: CorrelationEngine):
    """Events older than 30 minutes should be purged."""
    old_time = datetime.now() - timedelta(minutes=45)
    recent_time = datetime.now()

    # Insert old event directly to avoid auto-cleanup during record_event
    from maude.coordination.correlation import RoomEvent

    engine._events["postgresql"] = deque(
        [RoomEvent(room="postgresql", event_type="unhealthy", timestamp=old_time)],
        maxlen=500,
    )
    engine.record_event("monitoring", "unhealthy", timestamp=recent_time)

    # The old postgresql event should have been cleaned during record_event
    assert "postgresql" not in engine._events
    assert "monitoring" in engine._events


def test_cleanup_keeps_recent_events(engine: CorrelationEngine):
    """Events within 30 minutes should remain."""
    recent = datetime.now() - timedelta(minutes=10)
    engine.record_event("postgresql", "unhealthy", timestamp=recent)
    engine.record_event("monitoring", "unhealthy", timestamp=recent)

    removed = engine.cleanup()
    assert removed == 0
    assert len(engine._events) == 2


def test_cleanup_removes_empty_room_entries(engine: CorrelationEngine):
    """If all events for a room are purged, the room key should be removed."""
    old_time = datetime.now() - timedelta(minutes=45)
    engine.record_event("postgresql", "unhealthy", timestamp=old_time)
    engine.record_event("postgresql", "restart", timestamp=old_time + timedelta(seconds=10))

    engine.cleanup()
    assert "postgresql" not in engine._events


# ── Correlation score ─────────────────────────────────────────────


def test_closer_events_have_higher_score(engine: CorrelationEngine, now: datetime):
    """Events closer in time should produce a higher correlation score."""
    # Tight cluster
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(seconds=10))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(seconds=15))
    tight = engine.check_correlation("postgresql")

    # Reset
    engine._events.clear()
    engine._incidents.clear()

    # Loose cluster (still within 5 min)
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now + timedelta(minutes=4))
    engine.record_event("my-service", "unhealthy", timestamp=now + timedelta(minutes=4, seconds=30))
    loose = engine.check_correlation("postgresql")

    assert tight is not None
    assert loose is not None
    assert tight.correlation_score > loose.correlation_score


def test_score_bounded_zero_to_one(engine: CorrelationEngine, now: datetime):
    """Score should always be between 0.0 and 1.0."""
    engine.record_event("postgresql", "unhealthy", timestamp=now)
    engine.record_event("monitoring", "unhealthy", timestamp=now)
    engine.record_event("my-service", "unhealthy", timestamp=now)
    engine.record_event("scada", "unhealthy", timestamp=now)

    result = engine.check_correlation("postgresql")
    assert result is not None
    assert 0.0 <= result.correlation_score <= 1.0
