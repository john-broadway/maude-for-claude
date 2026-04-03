# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for EventListener — PG LISTEN subscriber with ring buffer."""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination.event_listener import CHANNEL, EventListener


@pytest.fixture
def deps() -> MagicMock:
    """Mock DependencyGraph."""
    d = MagicMock()
    d.affected_by.return_value = ["monitoring", "hmi"]
    return d


@pytest.fixture
def listener(deps: MagicMock) -> EventListener:
    return EventListener(
        dsn_kwargs={"host": "localhost", "database": "agent"},
        dependency_graph=deps,
        buffer_size=100,
    )


# ── Construction ──────────────────────────────────────────────────


def test_init(listener: EventListener):
    assert listener._running is False
    assert listener._conn is None
    assert listener.buffer_size == 0
    assert listener.is_running is False


def test_default_buffer_size():
    """Default buffer maxlen should be 500."""
    el = EventListener(dsn_kwargs={"host": "localhost"})
    assert el._buffer.maxlen == 500


def test_custom_buffer_size():
    el = EventListener(dsn_kwargs={"host": "localhost"}, buffer_size=10)
    assert el._buffer.maxlen == 10


# ── start / stop ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_start_success(listener: EventListener):
    mock_conn = AsyncMock()
    with patch("maude.coordination.event_listener.asyncpg.connect", return_value=mock_conn):
        await listener.start()
    assert listener.is_running is True
    mock_conn.add_listener.assert_awaited_once_with(CHANNEL, listener._on_notify)
    await listener.stop()


@pytest.mark.asyncio
async def test_start_failure_starts_reconnect_loop(listener: EventListener):
    """When initial connect fails, the listener still starts (reconnect loop active)."""
    with patch("maude.coordination.event_listener.asyncpg.connect", side_effect=Exception("boom")):
        await listener.start()
    # Listener is "running" — the reconnect loop is active
    assert listener.is_running is True
    assert listener._conn is None
    assert listener._reconnect_task is not None
    await listener.stop()


@pytest.mark.asyncio
async def test_start_idempotent(listener: EventListener):
    """Calling start() twice should not reconnect."""
    mock_conn = AsyncMock()
    with patch("maude.coordination.event_listener.asyncpg.connect", return_value=mock_conn):
        await listener.start()
        await listener.start()
    # connect called only once
    assert mock_conn.add_listener.await_count == 1
    await listener.stop()


@pytest.mark.asyncio
async def test_stop_cleans_up(listener: EventListener):
    mock_conn = AsyncMock()
    with patch("maude.coordination.event_listener.asyncpg.connect", return_value=mock_conn):
        await listener.start()

    assert listener.is_running is True
    await listener.stop()
    assert listener.is_running is False
    assert listener._conn is None
    assert listener._reconnect_task is None


@pytest.mark.asyncio
async def test_stop_safe_when_not_connected(listener: EventListener):
    await listener.stop()  # Should not raise
    assert listener._conn is None


# ── _on_notify ────────────────────────────────────────────────────


def test_on_notify_buffers_event(listener: EventListener):
    payload = json.dumps(
        {
            "room": "my-service",
            "event": "agent_run_completed",
            "data": {"outcome": "resolved"},
            "ts": "2026-02-01T10:00:00Z",
        }
    )
    listener._on_notify(MagicMock(), 123, CHANNEL, payload)
    assert listener.buffer_size == 1
    event = list(listener._buffer)[0]
    assert event["room"] == "my-service"
    assert "received_at" in event


def test_on_notify_health_unhealthy_logs_downstream(listener: EventListener, deps: MagicMock):
    payload = json.dumps(
        {
            "room": "postgresql",
            "event": "health_status_changed",
            "data": {"status": "unhealthy", "reason": "disk full"},
            "ts": "2026-02-01T10:00:00Z",
        }
    )
    listener._on_notify(MagicMock(), 123, CHANNEL, payload)
    deps.affected_by.assert_called_once_with("postgresql")


def test_on_notify_health_healthy_skips_dep_check(listener: EventListener, deps: MagicMock):
    """Healthy transitions should NOT trigger downstream analysis."""
    payload = json.dumps(
        {
            "room": "my-service",
            "event": "health_status_changed",
            "data": {"status": "healthy"},
            "ts": "2026-02-01T10:00:00Z",
        }
    )
    listener._on_notify(MagicMock(), 123, CHANNEL, payload)
    deps.affected_by.assert_not_called()


def test_on_notify_bad_json_ignored(listener: EventListener):
    listener._on_notify(MagicMock(), 123, CHANNEL, "not json")
    assert listener.buffer_size == 0


def test_on_notify_no_deps_graph():
    """Without a dependency graph, health events are still buffered."""
    el = EventListener(dsn_kwargs={"host": "localhost"}, dependency_graph=None)
    payload = json.dumps(
        {
            "room": "my-service",
            "event": "health_status_changed",
            "data": {"status": "unhealthy"},
            "ts": "2026-02-01T10:00:00Z",
        }
    )
    el._on_notify(MagicMock(), 123, CHANNEL, payload)
    assert el.buffer_size == 1


# ── recent_events ─────────────────────────────────────────────────


def test_recent_events_empty(listener: EventListener):
    assert listener.recent_events() == []


def test_recent_events_returns_all(listener: EventListener):
    for i in range(5):
        listener._buffer.append({"room": f"room{i}", "event": "test"})
    assert len(listener.recent_events()) == 5


def test_recent_events_limit(listener: EventListener):
    for i in range(10):
        listener._buffer.append({"room": f"room{i}", "event": "test"})
    assert len(listener.recent_events(limit=3)) == 3


def test_recent_events_filter_by_room(listener: EventListener):
    listener._buffer.append({"room": "my-service", "event": "test"})
    listener._buffer.append({"room": "monitoring", "event": "test"})
    listener._buffer.append({"room": "my-service", "event": "other"})
    result = listener.recent_events(room="my-service")
    assert len(result) == 2
    assert all(e["room"] == "my-service" for e in result)


def test_recent_events_filter_by_event_type(listener: EventListener):
    listener._buffer.append({"room": "my-service", "event": "health_status_changed"})
    listener._buffer.append({"room": "monitoring", "event": "restart_performed"})
    result = listener.recent_events(event_type="restart_performed")
    assert len(result) == 1
    assert result[0]["event"] == "restart_performed"


def test_recent_events_combined_filter(listener: EventListener):
    listener._buffer.append({"room": "my-service", "event": "health_status_changed"})
    listener._buffer.append({"room": "my-service", "event": "restart_performed"})
    listener._buffer.append({"room": "monitoring", "event": "restart_performed"})
    result = listener.recent_events(room="my-service", event_type="restart_performed")
    assert len(result) == 1


def test_ring_buffer_evicts_old_events():
    el = EventListener(dsn_kwargs={"host": "localhost"}, buffer_size=3)
    for i in range(5):
        el._buffer.append({"room": f"room{i}", "event": "test"})
    assert el.buffer_size == 3
    rooms = [e["room"] for e in el._buffer]
    assert rooms == ["room2", "room3", "room4"]


# ── Relay integration ─────────────────────────────────────────────


def test_no_relay_no_error():
    """EventListener without relay still works — backward compat."""
    deps = MagicMock()
    deps.affected_by.return_value = ["my-service"]
    el = EventListener(
        dsn_kwargs={"host": "localhost"},
        dependency_graph=deps,
        # relay not passed
    )
    payload = json.dumps(
        {
            "room": "postgresql",
            "event": "health_status_changed",
            "data": {"status": "unhealthy"},
        }
    )
    el._on_notify(MagicMock(), 123, CHANNEL, payload)  # must not raise
    assert el.buffer_size == 1


@pytest.mark.asyncio
async def test_correlated_incident_fires_relay():
    """When correlation detects an incident, relay messages go to root + affected rooms."""
    deps = MagicMock()
    deps.affected_by.return_value = []

    relay = MagicMock()
    relay.send_lenient = AsyncMock(return_value=1)

    mock_correlated = MagicMock()
    mock_correlated.root_room = "postgresql"
    mock_correlated.affected_rooms = ["my-service", "monitoring"]
    mock_correlated.correlation_score = 0.9

    el = EventListener(
        dsn_kwargs={"host": "localhost"},
        dependency_graph=deps,
        relay=relay,
    )
    el._correlation = MagicMock()
    el._correlation.record_event = MagicMock()
    el._correlation.check_correlation.return_value = mock_correlated

    payload = json.dumps(
        {
            "room": "postgresql",
            "event": "health_status_changed",
            "data": {"status": "unhealthy"},
        }
    )
    el._on_notify(MagicMock(), 123, CHANNEL, payload)
    await asyncio.sleep(0.05)  # flush ensure_future + gather inside _relay_batch

    # root_room + 2 affected_rooms = 3 relay calls
    assert relay.send_lenient.await_count == 3
    called_rooms = {call.args[1] for call in relay.send_lenient.call_args_list}
    assert called_rooms == {"postgresql", "my-service", "monitoring"}


@pytest.mark.asyncio
async def test_unhealthy_downstream_fires_relay():
    """Upstream-unhealthy health event triggers relay warnings to affected rooms."""
    deps = MagicMock()
    deps.affected_by.return_value = ["panel", "monitoring"]

    relay = MagicMock()
    relay.send_lenient = AsyncMock(return_value=1)

    el = EventListener(
        dsn_kwargs={"host": "localhost"},
        dependency_graph=deps,
        relay=relay,
    )
    el._correlation = None  # disable correlation

    payload = json.dumps(
        {
            "room": "postgresql",
            "event": "health_status_changed",
            "data": {"status": "unhealthy"},
        }
    )
    el._on_notify(MagicMock(), 123, CHANNEL, payload)
    await asyncio.sleep(0.05)

    assert relay.send_lenient.await_count == 2
    called_rooms = {call.args[1] for call in relay.send_lenient.call_args_list}
    assert called_rooms == {"panel", "monitoring"}
