# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""FleetService — autonomy classification with in-process cache.

Unifies the ``_build_autonomy_data()`` helper that was called from 6 routes
in the old monolithic app.py. Caches results for 10 seconds to avoid
redundant DB queries within a single request cycle.
"""

from __future__ import annotations

import logging
import time
from typing import Any

from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph

logger = logging.getLogger(__name__)


class FleetService:
    """Builds and caches fleet-wide autonomy data."""

    def __init__(self, memory: CrossRoomMemory, deps: DependencyGraph) -> None:
        self._memory = memory
        self._deps = deps
        self._cache: tuple[list[dict[str, Any]], dict[str, Any]] | None = None
        self._cache_time: float = 0.0
        self._cache_ttl: float = 10.0  # seconds

    async def get_autonomy_data(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Return (rooms_data, fleet_stats), cached for 10s.

        Falls back to empty data with a db_unavailable flag if PG is down.
        """
        now = time.monotonic()
        if self._cache is not None and (now - self._cache_time) < self._cache_ttl:
            return self._cache

        try:
            result = await self._build()
        except Exception:
            logger.warning("Fleet data unavailable — database may be down", exc_info=True)
            fallback_rooms = [
                {"name": r, "status": "manual", "reason": "Database unavailable",
                 "last_check": None, "last_outcome": "", "last_summary": "",
                 "health_loop_active": False, "agent_active": False,
                 "health_loop_checks_24h": 0, "agent_runs_24h": 0,
                 "restarts_24h": 0, "escalations_24h": 0, "deps_health": [],
                 "db_unavailable": True}
                for r in sorted(self._deps.all_rooms)
            ]
            result = (fallback_rooms, {"db_unavailable": True})

        self._cache = result
        self._cache_time = now
        return result

    def invalidate(self) -> None:
        """Clear the cache (e.g. after a deploy)."""
        self._cache = None

    async def _build(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Build autonomy data for all rooms."""
        autonomy = await self._memory.autonomy_status(
            minutes_recent=3, minutes_history=1440,
        )
        stats = await self._memory.fleet_stats(minutes=1440)
        all_rooms = self._deps.all_rooms
        status_map = {s["project"]: s for s in autonomy}
        recent_rooms = {s["project"] for s in autonomy if s.get("is_recent")}

        rooms_data: list[dict[str, Any]] = []
        for room_name in sorted(all_rooms):
            s = status_map.get(room_name)
            is_recent = s.get("is_recent", False) if s else False
            hl_checks = s.get("health_loop_checks_24h", 0) if s else 0
            agent_runs = s.get("agent_runs_24h", 0) if s else 0

            if is_recent and (hl_checks > 0 or agent_runs > 0):
                status = "autonomous"
                reason = "Health loop active" if hl_checks > 0 else "Agent active"
            elif s and not is_recent:
                status = "degraded"
                reason = "No activity in last 3 min"
            else:
                status = "manual"
                reason = "No activity in 24h"

            upstream = self._deps.depends_on(room_name)
            deps_health = [
                {"name": dep, "healthy": dep in recent_rooms}
                for dep in upstream
            ]

            rooms_data.append({
                "name": room_name,
                "status": status,
                "reason": reason,
                "last_check": (
                    str(s["last_activity"]) if s and s.get("last_activity") else None
                ),
                "last_outcome": s.get("last_outcome", "") if s else "",
                "last_summary": s.get("last_summary", "") if s else "",
                "health_loop_active": is_recent and hl_checks > 0,
                "agent_active": agent_runs > 0,
                "health_loop_checks_24h": hl_checks,
                "agent_runs_24h": agent_runs,
                "restarts_24h": s.get("restarts_24h", 0) if s else 0,
                "escalations_24h": s.get("escalations_24h", 0) if s else 0,
                "deps_health": deps_health,
            })

        return rooms_data, stats
