# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Per-room and fleet-wide autonomy scoring from agent_memory.

Computes resolution rate, self-heal rate, escalation rate, false restart
rate, MTTR, and a composite autonomy score (0-100) for each Room.

Daily snapshots are stored in the ``autonomy_snapshots`` table for
trend analysis.

Usage:
    metrics = AutonomyMetrics()
    score = await metrics.room_score("my-service", hours=24)
    fleet = await metrics.fleet_scores(hours=24)
    await metrics.snapshot_daily("my-service")
    await metrics.close()
"""

import logging
from datetime import date
from typing import Any

from maude.db import LazyPool

logger = logging.getLogger(__name__)

# ── SQL ──────────────────────────────────────────────────────────────

_INCIDENT_COUNTS_SQL = """
    SELECT
        COUNT(*) FILTER (
            WHERE memory_type IN ('incident', 'escalation', 'remediation')
        ) AS total_incidents,
        COUNT(*) FILTER (
            WHERE outcome IN ('resolved', 'remediated')
        ) AS resolved_count,
        COUNT(*) FILTER (
            WHERE outcome = 'remediated'
        ) AS remediated_count,
        COUNT(*) FILTER (
            WHERE outcome IN ('resolved', 'remediated', 'failed', 'escalated')
        ) AS actionable_count,
        COUNT(*) FILTER (
            WHERE outcome = 'escalated'
        ) AS escalated_count,
        COUNT(*) FILTER (
            WHERE outcome != 'no_action'
        ) AS non_noop_count,
        COUNT(*) FILTER (
            WHERE memory_type = 'incident' AND outcome = 'failed'
        ) AS false_restart_count,
        COUNT(*) FILTER (
            WHERE memory_type = 'incident'
        ) AS incident_type_count
    FROM agent_memory
    WHERE project = $1
      AND created_at > NOW() - make_interval(hours => $2)
"""

_MTTR_SQL = """
    WITH incidents AS (
        SELECT created_at AS incident_at, project
        FROM agent_memory
        WHERE project = $1
          AND created_at > NOW() - make_interval(hours => $2)
          AND memory_type IN ('incident', 'escalation')
          AND outcome NOT IN ('resolved', 'remediated')
    ),
    resolutions AS (
        SELECT created_at AS resolved_at, project
        FROM agent_memory
        WHERE project = $1
          AND created_at > NOW() - make_interval(hours => $2)
          AND outcome IN ('resolved', 'remediated')
    ),
    paired AS (
        SELECT
            i.incident_at,
            (SELECT MIN(r.resolved_at)
             FROM resolutions r
             WHERE r.resolved_at > i.incident_at) AS resolved_at
        FROM incidents i
    )
    SELECT AVG(EXTRACT(EPOCH FROM (resolved_at - incident_at))) AS mttr
    FROM paired
    WHERE resolved_at IS NOT NULL
"""

_ALL_PROJECTS_SQL = """
    SELECT DISTINCT project
    FROM agent_memory
    WHERE created_at > NOW() - make_interval(hours => $1)
      AND memory_type IN ('incident', 'escalation', 'remediation')
    ORDER BY project
"""

_SNAPSHOT_UPSERT_SQL = """
    INSERT INTO autonomy_snapshots
        (project, snapshot_date, resolution_rate, self_heal_rate,
         escalation_rate, false_restart_rate, mttr_seconds,
         autonomy_score, total_incidents)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (project, snapshot_date)
    DO UPDATE SET
        resolution_rate    = EXCLUDED.resolution_rate,
        self_heal_rate     = EXCLUDED.self_heal_rate,
        escalation_rate    = EXCLUDED.escalation_rate,
        false_restart_rate = EXCLUDED.false_restart_rate,
        mttr_seconds       = EXCLUDED.mttr_seconds,
        autonomy_score     = EXCLUDED.autonomy_score,
        total_incidents    = EXCLUDED.total_incidents
"""


# ── Defaults when there are zero incidents ───────────────────────────

_DEFAULT_SCORES: dict[str, Any] = {
    "resolution_rate": 0.0,
    "self_heal_rate": 0.0,
    "escalation_rate": 0.0,
    "false_restart_rate": 0.0,
    "mttr_seconds": None,
    "autonomy_score": 0.0,
    "total_incidents": 0,
}


def compute_autonomy_score(
    resolution_rate: float,
    self_heal_rate: float,
    escalation_rate: float,
    false_restart_rate: float,
) -> float:
    """Weighted autonomy score scaled to 0-100."""
    raw = (
        0.40 * resolution_rate
        + 0.25 * self_heal_rate
        + 0.20 * (1.0 - escalation_rate)
        + 0.15 * (1.0 - false_restart_rate)
    )
    return round(min(max(raw * 100, 0.0), 100.0), 2)


class AutonomyMetrics:
    """Compute per-room and fleet-wide autonomy scores.

    Args:
        db_host: PostgreSQL host override (empty = resolve from credentials).
    """

    def __init__(self, db_host: str = "") -> None:
        self._db_host = db_host
        self._db = LazyPool(
            database="agent",
            db_host=db_host,
            min_size=1,
            max_size=3,
        )

    async def _ensure_pool(self):
        return await self._db.get()

    async def room_score(self, project: str, hours: int = 24) -> dict[str, Any]:
        """Compute autonomy metrics for a single room over *hours*."""
        pool = await self._ensure_pool()
        if pool is None:
            return {"project": project, **_DEFAULT_SCORES}

        try:
            row = await pool.fetchrow(_INCIDENT_COUNTS_SQL, project, hours)
            assert row is not None

            total_incidents: int = row["total_incidents"]
            if total_incidents == 0:
                return {"project": project, **_DEFAULT_SCORES}

            resolved: int = row["resolved_count"]
            remediated: int = row["remediated_count"]
            actionable: int = row["actionable_count"]
            escalated: int = row["escalated_count"]
            non_noop: int = row["non_noop_count"]
            false_restart: int = row["false_restart_count"]
            incident_type: int = row["incident_type_count"]

            resolution_rate = resolved / non_noop if non_noop else 0.0
            self_heal_rate = remediated / actionable if actionable else 0.0
            escalation_rate = escalated / total_incidents
            false_restart_rate = false_restart / incident_type if incident_type else 0.0

            # MTTR
            mttr_row = await pool.fetchrow(_MTTR_SQL, project, hours)
            mttr_seconds: float | None = None
            if mttr_row and mttr_row["mttr"] is not None:
                mttr_seconds = round(float(mttr_row["mttr"]), 1)

            score = compute_autonomy_score(
                resolution_rate,
                self_heal_rate,
                escalation_rate,
                false_restart_rate,
            )

            return {
                "project": project,
                "resolution_rate": round(resolution_rate, 4),
                "self_heal_rate": round(self_heal_rate, 4),
                "escalation_rate": round(escalation_rate, 4),
                "false_restart_rate": round(false_restart_rate, 4),
                "mttr_seconds": mttr_seconds,
                "autonomy_score": score,
                "total_incidents": total_incidents,
            }
        except Exception:
            logger.warning("AutonomyMetrics: room_score failed for %s", project, exc_info=True)
            return {"project": project, **_DEFAULT_SCORES}

    async def fleet_scores(self, hours: int = 24) -> list[dict[str, Any]]:
        """Compute autonomy metrics for all active rooms."""
        pool = await self._ensure_pool()
        if pool is None:
            return []

        try:
            rows = await pool.fetch(_ALL_PROJECTS_SQL, hours)
            results: list[dict[str, Any]] = []
            for row in rows:
                score = await self.room_score(row["project"], hours)
                results.append(score)
            return results
        except Exception:
            logger.warning("AutonomyMetrics: fleet_scores failed", exc_info=True)
            return []

    async def snapshot_daily(self, project: str) -> None:
        """Store today's 24h score in autonomy_snapshots (upsert)."""
        pool = await self._ensure_pool()
        if pool is None:
            return

        score = await self.room_score(project, hours=24)
        try:
            await pool.execute(
                _SNAPSHOT_UPSERT_SQL,
                project,
                date.today(),
                score["resolution_rate"],
                score["self_heal_rate"],
                score["escalation_rate"],
                score["false_restart_rate"],
                score["mttr_seconds"],
                score["autonomy_score"],
                score["total_incidents"],
            )
            logger.info("AutonomyMetrics: snapshot stored for %s", project)
        except Exception:
            logger.warning("AutonomyMetrics: snapshot_daily failed for %s", project, exc_info=True)

    async def get_trends(self, days: int = 7) -> list[dict[str, Any]]:
        """Retrieve daily autonomy snapshots for the last N days."""
        pool = await self._ensure_pool()
        if pool is None:
            return []
        try:
            rows = await pool.fetch(
                """
                SELECT project, snapshot_date, resolution_rate, self_heal_rate,
                       escalation_rate, false_restart_rate, mttr_seconds,
                       autonomy_score, total_incidents
                FROM autonomy_snapshots
                WHERE snapshot_date >= CURRENT_DATE - $1::int
                ORDER BY snapshot_date DESC, project
                """,
                days,
            )
            return [dict(r) for r in rows]
        except Exception:
            logger.warning("AutonomyMetrics: get_trends failed", exc_info=True)
            return []

    async def close(self) -> None:
        await self._db.close()
