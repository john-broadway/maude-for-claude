# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Cross-room memory queries — system-wide visibility.

Queries agent_memory and agent_audit_log WITHOUT the project filter,
giving the Coordinator visibility across all Rooms.

Optional Redis caching for expensive queries (30s TTL).
"""

import json
import logging
from datetime import datetime
from typing import Any

import asyncpg

from maude.db import LazyPool

logger = logging.getLogger(__name__)

# Cache TTL for frequently queried aggregates
_CACHE_TTL = 30  # seconds


class CrossRoomMemory:
    """Query agent memory and audit logs across all Rooms.

    Args:
        db_host: PostgreSQL host. Defaults to credentials file.
        database: Database name. Defaults to "agent".
        redis: Optional MaudeRedis for query caching.
    """

    RECENT_ACTIVITY_SQL = """
        SELECT id, project, memory_type, trigger, outcome, summary,
               tokens_used, model, created_at
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
        ORDER BY created_at DESC
        LIMIT $2
    """

    PROJECT_ACTIVITY_SQL = """
        SELECT id, project, memory_type, trigger, outcome, summary,
               tokens_used, model, created_at
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
          AND project = $2
        ORDER BY created_at DESC
        LIMIT $3
    """

    ROOM_SUMMARY_SQL = """
        SELECT project,
               COUNT(*) AS total_runs,
               COUNT(*) FILTER (WHERE outcome = 'resolved') AS resolved,
               COUNT(*) FILTER (WHERE outcome = 'failed') AS failed,
               COUNT(*) FILTER (WHERE outcome = 'escalated') AS escalated,
               COUNT(*) FILTER (WHERE outcome = 'no_action') AS no_action,
               COUNT(*) FILTER (WHERE outcome = 'remediated') AS remediated,
               MAX(created_at) AS last_activity
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
        GROUP BY project
        ORDER BY project
    """

    INCIDENTS_SQL = """
        SELECT id, project, memory_type, trigger, outcome, summary, created_at
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
          AND outcome IN ('resolved', 'failed', 'escalated')
          AND memory_type != 'check'
        ORDER BY created_at DESC
        LIMIT 50
    """

    ESCALATIONS_SQL = """
        SELECT id, project, memory_type, trigger, outcome, summary, created_at
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
          AND outcome = 'escalated'
        ORDER BY created_at DESC
        LIMIT 50
    """

    REMEDIATIONS_SQL = """
        SELECT id, project, memory_type, trigger, outcome, summary,
               actions_taken, created_at
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
          AND memory_type = 'remediation'
        ORDER BY created_at DESC
        LIMIT 50
    """

    AUTONOMY_STATUS_SQL = """
        SELECT
            project,
            MAX(created_at) AS last_activity,
            (array_agg(outcome ORDER BY created_at DESC))[1] AS last_outcome,
            (array_agg(summary ORDER BY created_at DESC))[1] AS last_summary,
            (array_agg(model ORDER BY created_at DESC))[1] AS last_model,
            COUNT(*) FILTER (WHERE model = 'health_loop') AS health_loop_checks_24h,
            COUNT(*) FILTER (WHERE model != 'health_loop') AS agent_runs_24h,
            COUNT(*) FILTER (
                WHERE outcome = 'resolved' AND trigger = 'health_loop'
            ) AS restarts_24h,
            COUNT(*) FILTER (WHERE outcome = 'escalated') AS escalations_24h,
            bool_or(created_at > NOW() - ($1 || ' minutes')::interval) AS is_recent
        FROM agent_memory
        WHERE created_at > NOW() - ($2 || ' minutes')::interval
        GROUP BY project
        ORDER BY project
    """

    FLEET_STATS_SQL = """
        SELECT
            COUNT(*) FILTER (WHERE model = 'health_loop') AS total_health_checks,
            COUNT(*) FILTER (WHERE model != 'health_loop') AS total_agent_runs,
            COUNT(*) FILTER (
                WHERE outcome = 'resolved' AND trigger = 'health_loop'
            ) AS total_restarts,
            COUNT(*) FILTER (WHERE outcome = 'escalated') AS total_escalations,
            COUNT(*) FILTER (WHERE outcome = 'failed') AS total_failures
        FROM agent_memory
        WHERE created_at > NOW() - ($1 || ' minutes')::interval
    """

    AUDIT_RESTARTS_SQL = """
        SELECT project, tool, caller, params, result_summary, success,
               timestamp AS created_at
        FROM agent_audit_log
        WHERE timestamp > NOW() - ($1 || ' minutes')::interval
          AND tool LIKE 'health_loop.%restart%'
        ORDER BY timestamp DESC
        LIMIT 50
    """

    def __init__(
        self,
        db_host: str = "",
        database: str = "agent",
        redis: Any = None,
    ) -> None:
        self.database = database
        self._db_host = db_host
        self._db = LazyPool(database=database, db_host=db_host)
        self._redis = redis

    async def _cache_get(self, key: str) -> list[dict[str, Any]] | None:
        """Try to get cached result from Redis."""
        if not self._redis:
            return None
        try:
            cached = await self._redis.get(key)
            if cached:
                return json.loads(cached)
        except Exception:
            pass
        return None

    async def _cache_set(self, key: str, data: list[dict[str, Any]] | dict[str, Any]) -> None:
        """Cache result in Redis with TTL."""
        if not self._redis:
            return
        try:
            await self._redis.set(key, json.dumps(data, default=str), ttl=_CACHE_TTL)
        except Exception:
            pass

    async def _ensure_pool(self):
        """Lazy-init connection pool."""
        return await self._db.get()

    async def recent_activity(self, minutes: int = 60, limit: int = 200) -> list[dict[str, Any]]:
        """All Room Agent activity across the hotel."""
        cache_key = f"fd:activity:{minutes}"
        cached = await self._cache_get(cache_key)
        if cached is not None:
            return cached

        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.RECENT_ACTIVITY_SQL, str(minutes), limit)
            result = [self._row_to_dict(r) for r in rows]
            await self._cache_set(cache_key, result)
            return result
        except Exception:
            logger.warning("CrossRoomMemory: recent_activity query failed")
            return []

    async def project_activity(
        self, project: str, minutes: int = 60, limit: int = 50
    ) -> list[dict[str, Any]]:
        """Room Agent activity for a specific project."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.PROJECT_ACTIVITY_SQL, str(minutes), project, limit)
            return [self._row_to_dict(r) for r in rows]
        except Exception:
            logger.warning("CrossRoomMemory: project_activity query failed")
            return []

    async def all_rooms_summary(self, minutes: int = 60) -> list[dict[str, Any]]:
        """Per-room summary: run counts, outcomes, last activity."""
        cache_key = f"fd:summary:{minutes}"
        cached = await self._cache_get(cache_key)
        if cached is not None:
            return cached

        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.ROOM_SUMMARY_SQL, str(minutes))
            result = [dict(r) for r in rows]
            await self._cache_set(cache_key, result)
            return result
        except Exception:
            logger.warning("CrossRoomMemory: all_rooms_summary query failed")
            return []

    async def recent_incidents(self, minutes: int = 60) -> list[dict[str, Any]]:
        """Incidents (resolved, failed, escalated) across all Rooms."""
        cache_key = f"fd:incidents:{minutes}"
        cached = await self._cache_get(cache_key)
        if cached is not None:
            return cached

        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.INCIDENTS_SQL, str(minutes))
            result = [self._row_to_dict(r) for r in rows]
            await self._cache_set(cache_key, result)
            return result
        except Exception:
            logger.warning("CrossRoomMemory: recent_incidents query failed")
            return []

    async def recent_escalations(self, minutes: int = 60) -> list[dict[str, Any]]:
        """Escalations across all Rooms."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.ESCALATIONS_SQL, str(minutes))
            return [self._row_to_dict(r) for r in rows]
        except Exception:
            logger.warning("CrossRoomMemory: recent_escalations query failed")
            return []

    async def recent_remediations(self, minutes: int = 60) -> list[dict[str, Any]]:
        """Autonomous remediations across all Rooms."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.REMEDIATIONS_SQL, str(minutes))
            return [self._row_to_dict(r) for r in rows]
        except Exception:
            logger.warning("CrossRoomMemory: recent_remediations query failed")
            return []

    async def recent_restarts(self, minutes: int = 60) -> list[dict[str, Any]]:
        """Health loop restart actions from audit log."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(self.AUDIT_RESTARTS_SQL, str(minutes))
            results = []
            for r in rows:
                entry = dict(r)
                # Parse params JSON if stored as string
                if isinstance(entry.get("params"), str):
                    try:
                        entry["params"] = json.loads(entry["params"])
                    except Exception:
                        pass
                results.append(entry)
            return results
        except Exception:
            logger.warning("CrossRoomMemory: recent_restarts query failed")
            return []

    async def autonomy_status(
        self, minutes_recent: int = 3, minutes_history: int = 1440
    ) -> list[dict[str, Any]]:
        """Per-room autonomy data: last activity, counts, recency."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(
                self.AUTONOMY_STATUS_SQL,
                str(minutes_recent),
                str(minutes_history),
            )
            return [self._row_to_dict(r) for r in rows]
        except Exception:
            logger.warning("CrossRoomMemory: autonomy_status query failed", exc_info=True)
            return []

    async def fleet_stats(self, minutes: int = 1440) -> dict[str, Any]:
        """Fleet-wide totals for the autonomy page."""
        pool = await self._ensure_pool()
        if not pool:
            return {}
        try:
            row = await pool.fetchrow(self.FLEET_STATS_SQL, str(minutes))
            if row is None:
                return {}
            return dict(row)
        except Exception:
            logger.warning("CrossRoomMemory: fleet_stats query failed", exc_info=True)
            return {}

    async def close(self) -> None:
        """Close the connection pool."""
        await self._db.close()

    @staticmethod
    def _row_to_dict(row: asyncpg.Record) -> dict[str, Any]:
        """Convert a record to a serializable dict."""
        d = dict(row)
        # Convert datetimes to ISO strings
        for key, val in d.items():
            if isinstance(val, datetime):
                d[key] = val.isoformat()
        return d
