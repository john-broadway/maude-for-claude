# Maude Progress Tracker — observe tool execution timing and emit events.
# Version: 1.0.0
# Created: 2026-04-02 16:45 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Progress tracking for Room Agent tool executions.

Inspired by Claude Code's ``StreamingToolExecutor`` which yields progress
messages separately from final results. Maude's tools block until completion —
this module adds observability without changing tool interfaces.

Tracks:
- Tool execution start/end with timing
- Long-running tool detection (>threshold seconds)
- Accumulated progress events for dashboard consumption

Usage::

    tracker = ProgressTracker(project="example-scada")
    async with tracker.track("service_status") as ctx:
        result = await tool.run(args)
    events = tracker.get_recent()
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections import deque
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

logger = logging.getLogger(__name__)

# Default threshold before a tool is considered "long-running"
LONG_RUNNING_THRESHOLD_SECONDS = 5.0

# Max events kept in the ring buffer
MAX_EVENTS = 100


@dataclass
class ProgressEvent:
    """A single progress event from a tool execution."""

    project: str
    tool_name: str
    event_type: str  # "start", "running", "complete", "error"
    elapsed_seconds: float = 0.0
    detail: str = ""
    timestamp: float = field(default_factory=time.monotonic)


class ProgressTracker:
    """Track Room Agent tool execution progress.

    Maintains a ring buffer of recent events and optionally publishes
    to an asyncio.Queue for external consumers (dashboard, coordinator).

    Args:
        project: Room/project name.
        long_running_threshold: Seconds before emitting a "running" event.
        event_queue: Optional external queue to publish events to.
    """

    def __init__(
        self,
        project: str,
        long_running_threshold: float = LONG_RUNNING_THRESHOLD_SECONDS,
        event_queue: asyncio.Queue[ProgressEvent] | None = None,
    ) -> None:
        self.project = project
        self.threshold = long_running_threshold
        self._events: deque[ProgressEvent] = deque(maxlen=MAX_EVENTS)
        self._queue = event_queue
        self._active_tools: dict[str, float] = {}  # tool_name -> start_time

    def _emit(self, event: ProgressEvent) -> None:
        """Record an event and optionally publish to external queue."""
        self._events.append(event)
        if self._queue is not None:
            try:
                self._queue.put_nowait(event)
            except asyncio.QueueFull:
                pass  # drop if queue is full — non-blocking

    @asynccontextmanager
    async def track(self, tool_name: str) -> AsyncIterator[None]:
        """Context manager that tracks a tool execution.

        Emits "start" immediately, "running" if threshold exceeded,
        and "complete" or "error" on exit.
        """
        start = time.monotonic()
        self._active_tools[tool_name] = start
        self._emit(
            ProgressEvent(
                project=self.project,
                tool_name=tool_name,
                event_type="start",
            )
        )

        timer_task: asyncio.Task[None] | None = None

        async def _long_running_check() -> None:
            await asyncio.sleep(self.threshold)
            elapsed = time.monotonic() - start
            self._emit(
                ProgressEvent(
                    project=self.project,
                    tool_name=tool_name,
                    event_type="running",
                    elapsed_seconds=elapsed,
                    detail=f"{tool_name} still running after {elapsed:.1f}s",
                )
            )

        try:
            timer_task = asyncio.create_task(_long_running_check())
            yield
            elapsed = time.monotonic() - start
            self._emit(
                ProgressEvent(
                    project=self.project,
                    tool_name=tool_name,
                    event_type="complete",
                    elapsed_seconds=elapsed,
                )
            )
        except Exception as exc:
            elapsed = time.monotonic() - start
            self._emit(
                ProgressEvent(
                    project=self.project,
                    tool_name=tool_name,
                    event_type="error",
                    elapsed_seconds=elapsed,
                    detail=str(exc)[:200],
                )
            )
            raise
        finally:
            self._active_tools.pop(tool_name, None)
            if timer_task and not timer_task.done():
                timer_task.cancel()

    def get_recent(self, limit: int = 20) -> list[dict[str, Any]]:
        """Get recent progress events as dicts."""
        events = list(self._events)[-limit:]
        return [
            {
                "project": e.project,
                "tool": e.tool_name,
                "event": e.event_type,
                "elapsed": round(e.elapsed_seconds, 2),
                "detail": e.detail,
            }
            for e in events
        ]

    def get_active(self) -> list[dict[str, Any]]:
        """Get currently executing tools with elapsed time."""
        now = time.monotonic()
        return [
            {
                "tool": name,
                "elapsed": round(now - start_time, 2),
            }
            for name, start_time in self._active_tools.items()
        ]

    def clear(self) -> None:
        """Clear the event buffer."""
        self._events.clear()
