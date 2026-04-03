# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Correlation engine — detect correlated incidents across rooms.

Uses the dependency graph and temporal proximity to identify when
multiple rooms experience issues simultaneously, pointing to a
shared root cause (usually an upstream dependency).
"""

import logging
import uuid
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from maude.coordination.dependencies import DependencyGraph

logger = logging.getLogger(__name__)

# Events older than this are purged from the ring buffer
_BUFFER_WINDOW = timedelta(minutes=30)

# Events within this window are considered temporally correlated
_CORRELATION_WINDOW = timedelta(minutes=5)

# Minimum downstream rooms with concurrent issues to trigger correlation
_MIN_DOWNSTREAM = 2


@dataclass
class RoomEvent:
    """A single event recorded from a room."""

    room: str
    event_type: str
    timestamp: datetime
    data: dict = field(default_factory=dict)


@dataclass
class CorrelatedIncident:
    """A detected correlation between multiple room events."""

    id: str
    root_room: str
    affected_rooms: list[str]
    event_type: str
    timestamp: datetime
    correlation_score: float  # 0.0-1.0 based on temporal proximity and count
    resolved: bool = False


class CorrelationEngine:
    """Detect correlated incidents across rooms using dependency graph
    and temporal proximity.

    Args:
        dependency_graph: DependencyGraph for room topology.
    """

    def __init__(self, dependency_graph: DependencyGraph) -> None:
        self._deps = dependency_graph
        self._events: dict[str, deque[RoomEvent]] = {}
        self._incidents: deque[CorrelatedIncident] = deque(maxlen=200)

    def record_event(
        self,
        room: str,
        event_type: str,
        timestamp: datetime | None = None,
        data: dict | None = None,
    ) -> None:
        """Record an event from a room.

        Args:
            room: Room name (e.g. "postgresql").
            event_type: Event category (e.g. "unhealthy", "restart").
            timestamp: When the event occurred. Defaults to now.
            data: Optional metadata about the event.
        """
        ts = timestamp or datetime.now()
        event = RoomEvent(room=room, event_type=event_type, timestamp=ts, data=data or {})

        if room not in self._events:
            self._events[room] = deque(maxlen=500)
        self._events[room].append(event)

        self._cleanup_old_events()

    def check_correlation(self, room: str) -> CorrelatedIncident | None:
        """Check if the most recent event from a room correlates with
        events from other rooms via the dependency graph.

        Checks two directions:
        1. Downstream: rooms that depend on `room` — if 2+ have recent issues,
           `room` is likely the root cause.
        2. Upstream: rooms that `room` depends on — if an upstream room has
           recent issues, the upstream room is the root cause.

        Args:
            room: Room to check correlations for.

        Returns:
            CorrelatedIncident if correlation found, None otherwise.
        """
        latest = self._latest_event(room)
        if latest is None:
            return None

        # Direction 1: room is potential root cause (downstream affected)
        downstream = self._deps.depended_by(room)
        affected_downstream = self._rooms_with_recent_events(downstream, latest.timestamp)

        if len(affected_downstream) >= _MIN_DOWNSTREAM:
            score = self._compute_score(latest.timestamp, affected_downstream)
            incident = CorrelatedIncident(
                id=str(uuid.uuid4()),
                root_room=room,
                affected_rooms=sorted(affected_downstream),
                event_type=latest.event_type,
                timestamp=latest.timestamp,
                correlation_score=score,
            )
            self._incidents.append(incident)
            logger.info(
                "Correlated incident: root=%s affected=%s score=%.2f",
                room,
                affected_downstream,
                score,
            )
            return incident

        # Direction 2: room is affected, look for upstream root cause
        upstream = self._deps.depends_on(room)
        for up_room in upstream:
            up_event = self._latest_event(up_room)
            if up_event is None:
                continue
            delta = abs((latest.timestamp - up_event.timestamp).total_seconds())
            if delta > _CORRELATION_WINDOW.total_seconds():
                continue

            # Found unhealthy upstream — check if other downstream siblings are also affected
            siblings = self._deps.depended_by(up_room)
            affected_siblings = self._rooms_with_recent_events(siblings, up_event.timestamp)

            if len(affected_siblings) >= _MIN_DOWNSTREAM:
                score = self._compute_score(up_event.timestamp, affected_siblings)
                incident = CorrelatedIncident(
                    id=str(uuid.uuid4()),
                    root_room=up_room,
                    affected_rooms=sorted(affected_siblings),
                    event_type=up_event.event_type,
                    timestamp=up_event.timestamp,
                    correlation_score=score,
                )
                self._incidents.append(incident)
                logger.info(
                    "Upstream correlated incident: root=%s affected=%s score=%.2f",
                    up_room,
                    affected_siblings,
                    score,
                )
                return incident

        return None

    def recent_correlations(self, limit: int = 20) -> list[CorrelatedIncident]:
        """Return recent correlated incidents, newest first.

        Args:
            limit: Maximum number of incidents to return.

        Returns:
            List of CorrelatedIncident sorted by timestamp descending.
        """
        incidents = sorted(self._incidents, key=lambda i: i.timestamp, reverse=True)
        return incidents[:limit]

    def cleanup(self) -> int:
        """Remove events older than the buffer window.

        Returns:
            Number of events removed.
        """
        return self._cleanup_old_events()

    def _latest_event(self, room: str) -> RoomEvent | None:
        """Get the most recent event for a room."""
        buf = self._events.get(room)
        if not buf:
            return None
        return buf[-1]

    def _rooms_with_recent_events(
        self, rooms: list[str], reference_time: datetime
    ) -> list[str]:
        """Find rooms that have events within the correlation window
        of a reference time."""
        matched: list[str] = []
        cutoff = _CORRELATION_WINDOW.total_seconds()

        for r in rooms:
            buf = self._events.get(r)
            if not buf:
                continue
            for event in reversed(buf):
                delta = abs((reference_time - event.timestamp).total_seconds())
                if delta <= cutoff:
                    matched.append(r)
                    break
        return matched

    def _compute_score(self, reference_time: datetime, affected: list[str]) -> float:
        """Compute correlation score based on temporal proximity and count.

        Score factors:
        - More affected rooms = higher score
        - Closer timestamps = higher score
        """
        if not affected:
            return 0.0

        total_rooms = len(self._deps.all_rooms) or 1
        count_factor = min(len(affected) / total_rooms * 3, 1.0)

        proximity_scores: list[float] = []
        cutoff = _CORRELATION_WINDOW.total_seconds()
        for r in affected:
            buf = self._events.get(r)
            if not buf:
                continue
            for event in reversed(buf):
                delta = abs((reference_time - event.timestamp).total_seconds())
                if delta <= cutoff:
                    proximity_scores.append(1.0 - (delta / cutoff))
                    break

        avg_proximity = sum(proximity_scores) / len(proximity_scores) if proximity_scores else 0.0

        score = (count_factor * 0.4) + (avg_proximity * 0.6)
        return round(min(max(score, 0.0), 1.0), 3)

    def _cleanup_old_events(self) -> int:
        """Remove events older than the buffer window."""
        cutoff = datetime.now() - _BUFFER_WINDOW
        removed = 0

        for room in list(self._events):
            buf = self._events[room]
            while buf and buf[0].timestamp < cutoff:
                buf.popleft()
                removed += 1
            if not buf:
                del self._events[room]

        return removed
