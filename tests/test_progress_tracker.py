# Tests for progress tracker — tool execution observability.
# Version: 1.0.0
# Created: 2026-04-02 17:00 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Tests for maude.agent.progress — ProgressTracker."""

import asyncio

import pytest

from maude.healing.progress import MAX_EVENTS, ProgressEvent, ProgressTracker

# ── Basic tracking ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_track_emits_start_and_complete():
    tracker = ProgressTracker(project="grafana")

    async with tracker.track("service_status"):
        pass  # instant tool

    events = tracker.get_recent()
    assert len(events) == 2
    assert events[0]["event"] == "start"
    assert events[0]["tool"] == "service_status"
    assert events[1]["event"] == "complete"
    assert events[1]["elapsed"] >= 0


@pytest.mark.asyncio
async def test_track_emits_error_on_exception():
    tracker = ProgressTracker(project="grafana")

    with pytest.raises(ValueError, match="boom"):
        async with tracker.track("bad_tool"):
            raise ValueError("boom")

    events = tracker.get_recent()
    assert len(events) == 2
    assert events[0]["event"] == "start"
    assert events[1]["event"] == "error"
    assert "boom" in events[1]["detail"]


@pytest.mark.asyncio
async def test_track_long_running_emits_running_event():
    tracker = ProgressTracker(project="grafana", long_running_threshold=0.1)

    async with tracker.track("slow_tool"):
        await asyncio.sleep(0.2)

    events = tracker.get_recent()
    event_types = [e["event"] for e in events]
    assert "start" in event_types
    assert "running" in event_types
    assert "complete" in event_types


@pytest.mark.asyncio
async def test_track_fast_tool_no_running_event():
    tracker = ProgressTracker(project="grafana", long_running_threshold=10.0)

    async with tracker.track("fast_tool"):
        pass  # instant

    events = tracker.get_recent()
    event_types = [e["event"] for e in events]
    assert "running" not in event_types


# ── Active tools ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_active_during_execution():
    tracker = ProgressTracker(project="grafana")
    active_snapshot = []

    async with tracker.track("long_tool"):
        active_snapshot = tracker.get_active()

    assert len(active_snapshot) == 1
    assert active_snapshot[0]["tool"] == "long_tool"

    # After context manager exits, tool should no longer be active
    assert tracker.get_active() == []


# ── Event queue ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_event_queue_receives_events():
    queue: asyncio.Queue[ProgressEvent] = asyncio.Queue(maxsize=10)
    tracker = ProgressTracker(project="grafana", event_queue=queue)

    async with tracker.track("tool_a"):
        pass

    events = []
    while not queue.empty():
        events.append(queue.get_nowait())

    assert len(events) == 2
    assert events[0].event_type == "start"
    assert events[1].event_type == "complete"


@pytest.mark.asyncio
async def test_event_queue_full_does_not_block():
    """Full queue drops events silently — never blocks the tool."""
    queue: asyncio.Queue[ProgressEvent] = asyncio.Queue(maxsize=1)
    tracker = ProgressTracker(project="grafana", event_queue=queue)

    # This should not raise even though queue fills up
    async with tracker.track("tool_a"):
        pass

    assert queue.qsize() <= 1  # only first event fits


# ── Ring buffer ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_ring_buffer_caps_at_max():
    tracker = ProgressTracker(project="grafana")

    for i in range(MAX_EVENTS + 20):
        async with tracker.track(f"tool_{i}"):
            pass

    events = tracker.get_recent(limit=MAX_EVENTS + 100)
    assert len(events) <= MAX_EVENTS


def test_clear():
    tracker = ProgressTracker(project="grafana")
    tracker._events.append(ProgressEvent(project="grafana", tool_name="test", event_type="start"))
    assert len(tracker.get_recent()) == 1
    tracker.clear()
    assert len(tracker.get_recent()) == 0


# ── get_recent ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_recent_respects_limit():
    tracker = ProgressTracker(project="grafana")

    for i in range(5):
        async with tracker.track(f"tool_{i}"):
            pass

    events = tracker.get_recent(limit=3)
    assert len(events) == 3


@pytest.mark.asyncio
async def test_get_recent_empty():
    tracker = ProgressTracker(project="grafana")
    assert tracker.get_recent() == []


# ── ProgressEvent dataclass ──────────────────────────────────────────


def test_progress_event_defaults():
    event = ProgressEvent(project="grafana", tool_name="test", event_type="start")
    assert event.elapsed_seconds == 0.0
    assert event.detail == ""
    assert event.timestamp > 0
