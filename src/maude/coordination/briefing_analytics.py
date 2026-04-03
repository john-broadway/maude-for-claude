# Maude Briefing Analytics — lightweight pattern detection for briefing enrichment.
# Version: 1.0.0
# Created: 2026-04-01
# Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)
"""Briefing analytics — lightweight pattern detection for briefing enrichment.

No LLM required. Uses SQL aggregation and threshold logic to surface:
- Repeat offenders (rooms with recurring issues)
- Restart loops (rooms restarting too frequently)
- Escalation spikes (rooms escalating disproportionately)
- Trending rooms (incident count increasing vs prior period)
"""

import logging
from typing import Any

from maude.db import PoolRegistry

logger = logging.getLogger(__name__)

# ── SQL Queries ──────────────────────────────────────────────────────

_REPEAT_OFFENDERS_SQL = """
    SELECT project, COUNT(*) AS incident_count,
           COUNT(*) FILTER (WHERE outcome = 'failed') AS failed_count,
           COUNT(*) FILTER (WHERE outcome = 'escalated') AS escalated_count,
           COUNT(*) FILTER (WHERE outcome = 'remediated') AS remediated_count
    FROM agent_memory
    WHERE created_at > NOW() - make_interval(mins => $1)
      AND memory_type IN ('incident', 'escalation', 'remediation')
    GROUP BY project
    HAVING COUNT(*) >= $2
    ORDER BY COUNT(*) DESC
    LIMIT 10
"""

_RESTART_LOOPS_SQL = """
    SELECT project, COUNT(*) AS restart_count
    FROM agent_memory
    WHERE created_at > NOW() - make_interval(mins => $1)
      AND summary ILIKE '%restart%'
      AND outcome IN ('resolved', 'remediated')
    GROUP BY project
    HAVING COUNT(*) >= $2
    ORDER BY COUNT(*) DESC
"""

_TRENDING_SQL = """
    WITH current_period AS (
        SELECT project, COUNT(*) AS cnt
        FROM agent_memory
        WHERE created_at > NOW() - make_interval(mins => $1)
          AND memory_type IN ('incident', 'escalation', 'remediation')
        GROUP BY project
    ),
    prior_period AS (
        SELECT project, COUNT(*) AS cnt
        FROM agent_memory
        WHERE created_at > NOW() - make_interval(mins => $1 * 2)
          AND created_at <= NOW() - make_interval(mins => $1)
          AND memory_type IN ('incident', 'escalation', 'remediation')
        GROUP BY project
    )
    SELECT
        COALESCE(c.project, p.project) AS project,
        COALESCE(c.cnt, 0) AS current_count,
        COALESCE(p.cnt, 0) AS prior_count
    FROM current_period c
    FULL OUTER JOIN prior_period p ON c.project = p.project
    WHERE COALESCE(c.cnt, 0) > 0 OR COALESCE(p.cnt, 0) > 0
    ORDER BY COALESCE(c.cnt, 0) DESC
"""

_ESCALATION_RATE_SQL = """
    SELECT project,
           COUNT(*) AS total,
           COUNT(*) FILTER (WHERE outcome = 'escalated') AS escalated
    FROM agent_memory
    WHERE created_at > NOW() - make_interval(mins => $1)
      AND memory_type IN ('incident', 'escalation', 'remediation')
    GROUP BY project
    HAVING COUNT(*) >= 3
    ORDER BY COUNT(*) FILTER (WHERE outcome = 'escalated')::float / COUNT(*) DESC
"""

# ── Thresholds ───────────────────────────────────────────────────────

_MIN_INCIDENTS_FOR_REPEAT = 3
_MIN_RESTARTS_FOR_LOOP = 3
_TRENDING_THRESHOLD = 1.5  # 50% increase triggers trending alert
_ESCALATION_RATE_THRESHOLD = 0.3  # 30% escalation rate is concerning


class BriefingAnalytics:
    """Lightweight analytics for briefing enrichment.

    Queries agent_memory directly via LazyPool. Returns plain-text
    insight strings for injection into BriefingGenerator output.

    Args:
        db_host: PostgreSQL host override (empty = resolve from credentials).
    """

    def __init__(self, db_host: str = "") -> None:
        self._db = PoolRegistry.get(database="agent", db_host=db_host, min_size=1, max_size=3)

    async def analyze(self, minutes: int = 60) -> list[str]:
        """Run all analytics and return insight strings.

        Args:
            minutes: Lookback window matching the briefing scope.

        Returns:
            List of human-readable insight strings. Empty if nothing notable.
        """
        pool = await self._db.get()
        if pool is None:
            logger.warning("BriefingAnalytics: database pool unavailable, skipping")
            return ["Analytics unavailable — database unreachable"]

        insights: list[str] = []
        try:
            insights.extend(await self._repeat_offenders(pool, minutes))
            insights.extend(await self._restart_loops(pool, minutes))
            insights.extend(await self._escalation_spikes(pool, minutes))
            insights.extend(await self._trending_rooms(pool, minutes))
        except Exception:
            logger.warning("BriefingAnalytics: analyze failed", exc_info=True)

        return insights

    async def _repeat_offenders(self, pool: Any, minutes: int) -> list[str]:
        """Rooms with >= N incidents in the window."""
        rows = await pool.fetch(
            _REPEAT_OFFENDERS_SQL,
            minutes,
            _MIN_INCIDENTS_FOR_REPEAT,
        )
        insights: list[str] = []
        for row in rows:
            project = row["project"]
            count = row["incident_count"]
            failed = row["failed_count"]
            escalated = row["escalated_count"]
            remediated = row["remediated_count"]

            parts = [f"{count} incidents"]
            if failed:
                parts.append(f"{failed} failed")
            if escalated:
                parts.append(f"{escalated} escalated")
            if remediated:
                parts.append(f"{remediated} self-healed")

            insights.append(f"{project}: {', '.join(parts)} in last {minutes}min")

        return insights

    async def _restart_loops(self, pool: Any, minutes: int) -> list[str]:
        """Rooms restarting too frequently — possible restart loop."""
        rows = await pool.fetch(
            _RESTART_LOOPS_SQL,
            minutes,
            _MIN_RESTARTS_FOR_LOOP,
        )
        return [
            f"{row['project']}: {row['restart_count']} restarts in last "
            f"{minutes}min — possible restart loop"
            for row in rows
        ]

    async def _escalation_spikes(self, pool: Any, minutes: int) -> list[str]:
        """Rooms with escalation rate above threshold."""
        rows = await pool.fetch(_ESCALATION_RATE_SQL, minutes)
        insights: list[str] = []
        for row in rows:
            total = row["total"]
            escalated = row["escalated"]
            rate = escalated / total if total > 0 else 0.0
            if rate >= _ESCALATION_RATE_THRESHOLD:
                insights.append(
                    f"{row['project']}: {escalated}/{total} escalated "
                    f"({rate:.0%}) — needs investigation"
                )
        return insights

    async def _trending_rooms(self, pool: Any, minutes: int) -> list[str]:
        """Rooms with significantly more incidents than the prior period."""
        rows = await pool.fetch(_TRENDING_SQL, minutes)
        insights: list[str] = []
        for row in rows:
            current = row["current_count"]
            prior = row["prior_count"]

            if prior > 0 and current >= prior * _TRENDING_THRESHOLD and current >= 3:
                pct = ((current - prior) / prior) * 100
                insights.append(
                    f"{row['project']}: trending up — {current} incidents "
                    f"vs {prior} prior period (+{pct:.0f}%)"
                )
            elif prior == 0 and current >= _MIN_INCIDENTS_FOR_REPEAT:
                insights.append(
                    f"{row['project']}: new issues — {current} incidents (none in prior period)"
                )

        return insights

    async def close(self) -> None:
        """Close the database pool."""
        await self._db.close()
