# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Diagnostic tracer — trace data pipelines and dependency chains.

Provides structured pipeline analysis across rooms: follow data from
PLC -> Collector -> PostgreSQL -> Grafana (or any custom chain) by
walking the dependency graph and collecting health/status from each hop.
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from maude.coordination.dependencies import DependencyGraph

logger = logging.getLogger(__name__)

# Well-known data pipeline definitions (source -> sink order)
_PIPELINES: dict[str, list[str]] = {
    "plc_to_monitoring": ["collector", "postgresql", "monitoring"],
    "plc_to_dashboard": ["collector", "postgresql", "dashboard"],
    "metrics": ["prometheus", "monitoring"],
    "logs": ["loki", "monitoring"],
}


@dataclass
class TraceHop:
    """Single hop in a diagnostic trace."""

    room: str
    status: str  # "healthy", "unhealthy", "unreachable", "skipped"
    detail: str
    latency_ms: float | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class TraceResult:
    """Complete trace of a pipeline or dependency chain."""

    name: str
    hops: list[TraceHop]
    timestamp: datetime = field(default_factory=datetime.now)
    healthy: bool = True  # False if any hop is not healthy

    @property
    def broken_at(self) -> str | None:
        """First unhealthy/unreachable room in the chain, or None."""
        for hop in self.hops:
            if hop.status in ("unhealthy", "unreachable"):
                return hop.room
        return None


class DiagnosticTracer:
    """Trace data pipelines and dependency chains across rooms.

    Uses the dependency graph for topology and an optional health
    checker callback to probe each room.

    Args:
        dependency_graph: Room topology.
        health_checker: Async callable(room: str) -> dict with at
            least "status" key. If None, returns "skipped" for all hops.
    """

    def __init__(
        self,
        dependency_graph: DependencyGraph,
        health_checker: Any | None = None,
    ) -> None:
        self._deps = dependency_graph
        self._check_health = health_checker

    async def trace_data_pipeline(self, pipeline: str = "plc_to_grafana") -> TraceResult:
        """Trace a named data pipeline end-to-end.

        Each room in the pipeline is probed for health. The trace
        identifies the first broken hop in the chain.

        Args:
            pipeline: Pipeline name from the built-in registry, or a
                comma-separated list of room names.

        Returns:
            TraceResult with per-hop status.
        """
        if pipeline in _PIPELINES:
            rooms = _PIPELINES[pipeline]
            name = pipeline
        else:
            rooms = [r.strip() for r in pipeline.split(",") if r.strip()]
            name = f"custom:{','.join(rooms)}"

        if not rooms:
            return TraceResult(name=name, hops=[], healthy=True)

        hops: list[TraceHop] = []
        all_healthy = True

        for room in rooms:
            if room not in self._deps.all_rooms:
                hop = TraceHop(
                    room=room,
                    status="unreachable",
                    detail=f"Room '{room}' not in dependency graph",
                )
                all_healthy = False
                hops.append(hop)
                continue

            hop = await self._probe_room(room)
            hops.append(hop)
            if hop.status != "healthy":
                all_healthy = False

        return TraceResult(name=name, hops=hops, healthy=all_healthy)

    async def trace_dependency_chain(self, room: str) -> TraceResult:
        """Trace the full upstream dependency chain for a room.

        Walks from the given room to all its transitive dependencies
        (deepest first), probing each for health. Useful for diagnosing
        "why is X unhealthy" by checking all upstream services.

        Args:
            room: Room to trace dependencies for.

        Returns:
            TraceResult with upstream rooms ordered deepest-first,
            followed by the target room itself.
        """
        if room not in self._deps.all_rooms:
            hop = TraceHop(
                room=room,
                status="unreachable",
                detail=f"Room '{room}' not in dependency graph",
            )
            return TraceResult(name=f"deps:{room}", hops=[hop], healthy=False)

        chain = self._resolve_upstream(room)

        hops: list[TraceHop] = []
        all_healthy = True

        for r in chain:
            hop = await self._probe_room(r)
            hops.append(hop)
            if hop.status != "healthy":
                all_healthy = False

        return TraceResult(name=f"deps:{room}", hops=hops, healthy=all_healthy)

    @property
    def available_pipelines(self) -> list[str]:
        """List built-in pipeline names."""
        return sorted(_PIPELINES.keys())

    async def _probe_room(self, room: str) -> TraceHop:
        """Probe a single room for health status."""
        if self._check_health is None:
            return TraceHop(room=room, status="skipped", detail="No health checker configured")

        try:
            result = await self._check_health(room)
            status = result.get("status", "unknown")
            detail = result.get("detail", "")
            latency = result.get("latency_ms")
            skip = {"status", "detail", "latency_ms"}
            metadata = {k: v for k, v in result.items() if k not in skip}
            return TraceHop(
                room=room,
                status=status,
                detail=detail,
                latency_ms=latency,
                metadata=metadata,
            )
        except Exception as exc:
            logger.warning("Health check failed for %s: %s", room, exc)
            return TraceHop(
                room=room,
                status="unreachable",
                detail=f"Health check error: {exc}",
            )

    def _resolve_upstream(self, room: str) -> list[str]:
        """Resolve the full upstream chain, deepest-first, ending with room itself.

        Uses BFS to find all transitive upstream deps, then reverses to
        produce deepest-first order (leaf deps first, target room last).
        """
        visited: list[str] = []
        seen: set[str] = set()
        queue = [room]

        while queue:
            current = queue.pop(0)
            if current in seen:
                continue
            seen.add(current)
            visited.append(current)
            for dep in self._deps.depends_on(current):
                if dep not in seen:
                    queue.append(dep)

        # Reverse: deepest dependencies first, target room last
        visited.reverse()
        return visited
