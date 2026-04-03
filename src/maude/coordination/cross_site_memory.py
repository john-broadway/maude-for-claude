# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Cross-site memory aggregation for Maude.

Connects to PostgreSQL instances at each site to provide
system-wide visibility into agent_memory and agent_audit_log.

"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)

# Seconds before retrying a failed site connection
_RETRY_COOLDOWN = 60.0


@dataclass
class SiteConnection:
    """Connection state for one site's PostgreSQL instance."""

    site: str
    host: str
    port: int
    database: str
    user: str
    password: str
    _pool: asyncpg.Pool | None = field(default=None, repr=False, compare=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False, compare=False)
    _last_failure: float = field(default=0.0, repr=False, compare=False)

    async def get_pool(self) -> asyncpg.Pool | None:
        """Lazy-init connection pool. Returns None if site is unreachable."""
        if self._pool is not None:
            return self._pool
        async with self._lock:
            if self._pool is not None:
                return self._pool
            elapsed = time.monotonic() - self._last_failure
            if self._last_failure and elapsed < _RETRY_COOLDOWN:
                return None
            try:
                self._pool = await asyncpg.create_pool(
                    host=self.host,
                    port=self.port,
                    database=self.database,
                    user=self.user,
                    password=self.password,
                    min_size=1,
                    max_size=3,
                )
                self._last_failure = 0.0
                return self._pool
            except Exception:
                self._last_failure = time.monotonic()
                logger.warning(
                    "CrossSiteMemory: site %s (%s) unavailable",
                    self.site,
                    self.host,
                    exc_info=True,
                )
                return None

    async def close(self) -> None:
        """Close the connection pool."""
        if self._pool is not None:
            await self._pool.close()
            self._pool = None


class CrossSiteMemory:
    """Aggregates agent memory and audit logs across multiple sites.

    Each site has its own PostgreSQL instance. This class maintains
    lazy connections to each and provides unified query interfaces.

    Args:
        sites: Dict of site_name -> {host, port, user, password, database}
               Loaded from the ``federation`` section of secrets.yaml.
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

    def __init__(self, sites: dict[str, dict[str, Any]]) -> None:
        self._sites: dict[str, SiteConnection] = {}
        for name, cfg in sites.items():
            self._sites[name] = SiteConnection(
                site=name,
                host=cfg["host"],
                port=int(cfg.get("port", 5432)),
                database=str(cfg.get("database", "agent")),
                user=str(cfg.get("user", "support")),
                password=str(cfg.get("password", "")),
            )

    @property
    def site_names(self) -> list[str]:
        """Names of all configured sites."""
        return list(self._sites)

    async def all_sites_summary(self, minutes: int = 60) -> dict[str, list[dict[str, Any]]]:
        """Get recent memory summary across all sites.

        Queries all sites in parallel. Unreachable sites return empty lists.

        Returns:
            Dict of site_name -> list of per-room run summaries.
        """
        site_names = list(self._sites)
        results = await asyncio.gather(
            *(self._query_site(name, self.ROOM_SUMMARY_SQL, str(minutes)) for name in site_names),
            return_exceptions=True,
        )
        summary: dict[str, list[dict[str, Any]]] = {}
        for name, result in zip(site_names, results):
            if isinstance(result, BaseException):
                logger.warning("CrossSiteMemory: summary query failed for %s: %s", name, result)
                summary[name] = []
            else:
                for row in result:
                    row["site"] = name
                summary[name] = result
        return summary

    async def recent_incidents(
        self, minutes: int = 60, site: str | None = None
    ) -> list[dict[str, Any]]:
        """Get recent incidents, optionally filtered by site.

        Args:
            minutes: Lookback window in minutes.
            site: If set, query only this site. Otherwise queries all sites.

        Returns:
            Flat list sorted by created_at descending. Each row includes a 'site' field.
        """
        target = [site] if site else list(self._sites)
        results = await asyncio.gather(
            *(self._query_site(s, self.INCIDENTS_SQL, str(minutes)) for s in target),
            return_exceptions=True,
        )
        combined: list[dict[str, Any]] = []
        for site_name, result in zip(target, results):
            if isinstance(result, BaseException):
                logger.warning("CrossSiteMemory: incidents query failed for %s", site_name)
                continue
            for row in result:
                row["site"] = site_name
                combined.append(row)
        combined.sort(key=lambda r: r.get("created_at", ""), reverse=True)
        return combined

    async def recent_escalations(
        self, minutes: int = 60, site: str | None = None
    ) -> list[dict[str, Any]]:
        """Get recent escalations across sites.

        Args:
            minutes: Lookback window in minutes.
            site: If set, query only this site. Otherwise queries all sites.

        Returns:
            Flat list sorted by created_at descending. Each row includes a 'site' field.
        """
        target = [site] if site else list(self._sites)
        results = await asyncio.gather(
            *(self._query_site(s, self.ESCALATIONS_SQL, str(minutes)) for s in target),
            return_exceptions=True,
        )
        combined: list[dict[str, Any]] = []
        for site_name, result in zip(target, results):
            if isinstance(result, BaseException):
                logger.warning("CrossSiteMemory: escalations query failed for %s", site_name)
                continue
            for row in result:
                row["site"] = site_name
                combined.append(row)
        combined.sort(key=lambda r: r.get("created_at", ""), reverse=True)
        return combined

    async def site_health_grid(self) -> dict[str, list[dict[str, Any]]]:
        """Get health status per room per site (last 60 minutes).

        Returns:
            Dict of site_name -> list of room health summaries.
        """
        return await self.all_sites_summary(minutes=60)

    async def _query_site(self, site: str, sql: str, *args: Any) -> list[dict[str, Any]]:
        """Execute a query against a specific site's PostgreSQL.

        Args:
            site: Site name key in self._sites.
            sql: SQL query string.
            *args: Positional query parameters.

        Returns:
            List of row dicts. Empty list if site is unavailable.
        """
        conn = self._sites.get(site)
        if conn is None:
            return []
        pool = await conn.get_pool()
        if pool is None:
            return []
        try:
            rows = await pool.fetch(sql, *args)
            return [self._row_to_dict(r) for r in rows]
        except Exception:
            logger.warning("CrossSiteMemory: query failed for site %s", site, exc_info=True)
            return []

    async def close(self) -> None:
        """Close all site connection pools."""
        await asyncio.gather(*(conn.close() for conn in self._sites.values()))

    @staticmethod
    def _row_to_dict(row: asyncpg.Record) -> dict[str, Any]:
        """Convert a record to a serializable dict."""
        d = dict(row)
        for key, val in d.items():
            if isinstance(val, datetime):
                d[key] = val.isoformat()
        return d
