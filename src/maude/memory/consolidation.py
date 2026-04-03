"""Vault memory consolidation — cluster similar memories and extract patterns.

Version: 1.0.0
Created: 2026-03-05 21:45 MST
Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)

Phase 3 of the Vault memory system. Groups semantically similar memories
from the Qdrant vault collection and extracts recurring patterns into the
``memory_patterns`` PostgreSQL table.

Unlike the older ``memory_consolidator.py`` (which uses the
``memory_consolidation`` mapping table), this module writes to
``memory_patterns`` — a dedicated table for storing consolidated
trigger/resolution patterns with frequency tracking.
"""

from __future__ import annotations

import logging
import re
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Any

import asyncpg
from qdrant_client import AsyncQdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchValue

from maude.daemon.common import pg_pool_kwargs
from maude.memory.types import get_policy

logger = logging.getLogger(__name__)

VAULT_COLLECTION = "vault"
SIMILARITY_THRESHOLD = 0.80
MIN_CLUSTER_SIZE = 3
SCROLL_BATCH = 100

# ── Consolidation gate defaults ──────────────────────────────────────
# Inspired by Claude Code's autoDream.ts — three gates, cheapest first:
#   1. Time: hours since last consolidation >= min_hours
#   2. Volume: unconsolidated point count >= min_memories
#   3. Lock: PG advisory lock prevents concurrent runs
DEFAULT_MIN_HOURS = 24.0
DEFAULT_MIN_MEMORIES = 20

# PG advisory lock namespace — unique int64 for consolidation
_ADVISORY_LOCK_ID = 0x4348_524E_434F_4E53  # "CHRNCONS" as hex


# DDL reference (run as postgres superuser, not via this module):
# CREATE TABLE IF NOT EXISTS memory_patterns (
#     id SERIAL PRIMARY KEY, project TEXT NOT NULL,
#     pattern_type TEXT DEFAULT 'recurring', trigger_pattern TEXT NOT NULL,
#     resolution_pattern TEXT, frequency INTEGER DEFAULT 1,
#     last_seen TIMESTAMPTZ DEFAULT now(), source_memory_ids INTEGER[],
#     embedding FLOAT8[], created_at TIMESTAMPTZ DEFAULT now(),
#     updated_at TIMESTAMPTZ DEFAULT now()
# );

_FIND_OVERLAPPING_SQL = """
SELECT id, source_memory_ids, frequency, trigger_pattern, resolution_pattern, pattern_type
FROM memory_patterns
WHERE project = $1
ORDER BY id
"""

_DEPRECATE_PATTERN_SQL = """
UPDATE memory_patterns
SET pattern_type = 'deprecated',
    updated_at = now()
WHERE id = $1
"""

_INSERT_PATTERN_SQL = """
INSERT INTO memory_patterns
    (project, pattern_type, trigger_pattern, resolution_pattern,
     frequency, last_seen, source_memory_ids, embedding)
VALUES ($1, $2, $3, $4, $5, now(), $6, $7)
RETURNING id
"""

_UPDATE_PATTERN_SQL = """
UPDATE memory_patterns
SET trigger_pattern = $2,
    resolution_pattern = $3,
    frequency = $4,
    last_seen = now(),
    source_memory_ids = $5,
    embedding = $6,
    updated_at = now()
WHERE id = $1
"""


class MemoryConsolidator:
    """Cluster vault memories by semantic similarity and extract patterns.

    Scans the Qdrant vault collection per-project, finds clusters of 3+
    similar memories, and upserts patterns into the ``memory_patterns``
    table. Idempotent — overlapping source memory IDs trigger an update
    rather than a duplicate insert.

    Args:
        qdrant_host: Qdrant server host.
        qdrant_port: Qdrant server port.
        db_host: PostgreSQL host.
        db_name: PostgreSQL database name.
    """

    def __init__(
        self,
        qdrant_host: str = "192.0.2.32",
        qdrant_port: int = 6333,
        db_host: str = "192.0.2.30",
        db_name: str = "agent",
        min_hours: float = DEFAULT_MIN_HOURS,
        min_memories: int = DEFAULT_MIN_MEMORIES,
    ) -> None:
        self.qdrant_host = qdrant_host
        self.qdrant_port = qdrant_port
        self.db_host = db_host
        self.db_name = db_name
        self.min_hours = min_hours
        self.min_memories = min_memories
        self._qdrant: AsyncQdrantClient | None = None
        self._conn: asyncpg.Connection | None = None
        # Per-project last-consolidated timestamps (monotonic seconds)
        self._last_consolidated: dict[str, float] = {}

    async def _get_qdrant(self) -> AsyncQdrantClient:
        if self._qdrant is None:
            self._qdrant = AsyncQdrantClient(
                host=self.qdrant_host,
                port=self.qdrant_port,
                timeout=30,
            )
        return self._qdrant

    async def _get_conn(self) -> asyncpg.Connection:
        if self._conn is None or self._conn.is_closed():
            kw = pg_pool_kwargs(db_host=self.db_host, database=self.db_name)
            connect_kw = {k: v for k, v in kw.items() if k not in ("min_size", "max_size")}
            self._conn = await asyncpg.connect(**connect_kw)
        return self._conn

    # ── Three-gate consolidation pipeline ───────────────────────────

    def _check_time_gate(self, project: str) -> bool:
        """Gate 1 (cheapest): has enough time passed since last consolidation?"""
        last = self._last_consolidated.get(project, 0.0)
        if last == 0.0:
            return True  # Never consolidated — pass
        hours_since = (time.monotonic() - last) / 3600.0
        if hours_since < self.min_hours:
            logger.debug(
                "consolidate %s: time gate — %.1fh since last (need %.1fh)",
                project,
                hours_since,
                self.min_hours,
            )
            return False
        return True

    async def _check_volume_gate(
        self,
        client: AsyncQdrantClient,
        project: str,
    ) -> bool:
        """Gate 2: are there enough memories to justify consolidation?"""
        project_filter = Filter(
            must=[FieldCondition(key="project", match=MatchValue(value=project))]
        )
        try:
            count_result = await client.count(
                collection_name=VAULT_COLLECTION,
                count_filter=project_filter,
                exact=False,
            )
            raw_count = count_result.count if count_result else 0
            count = raw_count if isinstance(raw_count, int) else 0
        except Exception:
            logger.debug("consolidate %s: volume gate — count query failed, passing", project)
            return True  # If we can't check volume, don't block consolidation
        if count < self.min_memories:
            logger.debug(
                "consolidate %s: volume gate — %d points (need %d)",
                project,
                count,
                self.min_memories,
            )
            return False
        return True

    async def _try_acquire_lock(self, conn: asyncpg.Connection) -> bool:
        """Gate 3 (most expensive): acquire PG advisory lock.

        Uses ``pg_try_advisory_lock`` (non-blocking). The lock is
        session-scoped — released when the connection closes or
        explicitly via ``pg_advisory_unlock``.
        """
        try:
            acquired = await conn.fetchval("SELECT pg_try_advisory_lock($1)", _ADVISORY_LOCK_ID)
        except Exception:
            logger.debug("consolidate: lock gate — query failed, passing")
            return True  # If we can't check lock, don't block consolidation
        if not acquired:
            logger.debug("consolidate: lock gate — another process holds the lock")
        return bool(acquired)

    async def _release_lock(self, conn: asyncpg.Connection) -> None:
        """Release the PG advisory lock (rollback on failure)."""
        try:
            await conn.execute("SELECT pg_advisory_unlock($1)", _ADVISORY_LOCK_ID)
        except Exception:
            logger.debug("consolidate: lock release failed (non-fatal)")

    async def ensure_table(self) -> None:
        """Verify the memory_patterns table exists.

        DDL is handled by migration (the maude PG role lacks CREATE).
        This just checks and logs.
        """
        conn = await self._get_conn()
        exists = await conn.fetchval(
            "SELECT EXISTS(SELECT 1 FROM information_schema.tables "
            "WHERE table_name = 'memory_patterns')"
        )
        if not exists:
            logger.warning("memory_patterns table does not exist — run migration first")
            raise RuntimeError("memory_patterns table missing")

    async def consolidate_project(self, project: str) -> dict[str, int]:
        """Consolidate memories for a single project.

        Three-gate pipeline (cheapest first, inspired by Claude Code's
        autoDream.ts):
            1. Time gate — skip if < min_hours since last consolidation
            2. Volume gate — skip if < min_memories points in vault
            3. Lock gate — PG advisory lock prevents concurrent runs

        If all gates pass:
            4. Scroll vault collection for all points with this project.
            5. Cluster points by semantic similarity (>0.80 threshold).
            6. When 3+ memories cluster together, extract a pattern.
            7. Upsert to memory_patterns (idempotent via overlap check).

        Returns:
            Dict with keys ``patterns_found``, ``new``, ``updated``,
            ``gated`` (True if skipped due to a gate).
        """
        stats: dict[str, int] = {"patterns_found": 0, "new": 0, "updated": 0}

        # Gate 1: Time
        if not self._check_time_gate(project):
            return {**stats, "gated": 1}

        client = await self._get_qdrant()

        # Gate 2: Volume
        if not await self._check_volume_gate(client, project):
            return {**stats, "gated": 1}

        conn = await self._get_conn()

        # Gate 3: Lock
        if not await self._try_acquire_lock(conn):
            return {**stats, "gated": 1}

        try:
            stats = await self._do_consolidation(client, conn, project)
        except Exception:
            logger.warning("consolidate %s: failed, releasing lock", project, exc_info=True)
            raise
        finally:
            await self._release_lock(conn)
            # Record successful completion time (even on failure — prevents
            # retries from hammering every cycle)
            self._last_consolidated[project] = time.monotonic()

        return stats

    async def _do_consolidation(
        self,
        client: AsyncQdrantClient,
        conn: asyncpg.Connection,
        project: str,
    ) -> dict[str, int]:
        """Core consolidation logic (called after all gates pass).

        Enhanced with targeted consolidation strategy (inspired by
        Claude Code's four-phase pattern):
        - Type-aware filtering: only consolidate types whose policy allows it
        - Date normalization: convert relative dates in patterns to absolute
        - Contradiction detection: deprecate patterns superseded by new data
        """
        stats: dict[str, int] = {
            "patterns_found": 0,
            "new": 0,
            "updated": 0,
            "deprecated": 0,
        }

        # 1. Scroll all vault points for this project
        points = await self._scroll_project(client, project)

        # 1b. Type-aware filtering: only consolidate types whose policy
        # specifies a consolidation strategy (similarity or time_window)
        consolidatable = [
            p for p in points if get_policy(p.get("memory_type", "")).consolidate != "none"
        ]
        if len(consolidatable) < MIN_CLUSTER_SIZE:
            logger.info(
                "consolidate %s: only %d consolidatable points (of %d total), skipping",
                project,
                len(consolidatable),
                len(points),
            )
            return stats

        # 2. Cluster by similarity
        clusters = self._cluster_points(consolidatable)
        viable = [c for c in clusters if len(c) >= MIN_CLUSTER_SIZE]
        stats["patterns_found"] = len(viable)

        if not viable:
            logger.info(
                "consolidate %s: %d points, no clusters >= %d",
                project,
                len(consolidatable),
                MIN_CLUSTER_SIZE,
            )
            return stats

        # Load existing patterns for overlap + contradiction checks
        existing = await conn.fetch(_FIND_OVERLAPPING_SQL, project)

        for cluster in viable:
            trigger = _normalize_dates(_extract_trigger(cluster))
            resolution = _normalize_dates(_extract_resolution(cluster))
            source_ids = _extract_source_ids(cluster)
            centroid = cluster[0]["vector"]

            # Check overlap with existing patterns
            match = _find_overlapping_pattern(source_ids, existing)

            if match is not None:
                # Update: merge source IDs, bump frequency
                row_id = match["id"]
                old_ids = set(match["source_memory_ids"] or [])
                merged_ids = sorted(old_ids | source_ids)
                new_freq = len(merged_ids)
                await conn.execute(
                    _UPDATE_PATTERN_SQL,
                    row_id,
                    _normalize_dates(trigger),
                    resolution,
                    new_freq,
                    merged_ids,
                    centroid,
                )
                stats["updated"] += 1
                logger.debug(
                    "consolidate %s: updated pattern #%d (%d memories)", project, row_id, new_freq
                )
            else:
                # Contradiction detection: if a non-deprecated pattern exists
                # with similar trigger keywords but a different resolution,
                # deprecate the older one (superseded by new evidence).
                deprecated_count = await self._deprecate_contradicted(
                    conn, existing, trigger, resolution
                )
                stats["deprecated"] += deprecated_count

                # Insert new pattern
                row_id = await conn.fetchval(
                    _INSERT_PATTERN_SQL,
                    project,
                    "recurring",
                    trigger,
                    resolution,
                    len(source_ids),
                    sorted(source_ids),
                    centroid,
                )
                stats["new"] += 1
                logger.debug(
                    "consolidate %s: new pattern #%d (%d memories)",
                    project,
                    row_id,
                    len(source_ids),
                )

        logger.info(
            "consolidate %s: %d patterns (%d new, %d updated, %d deprecated)",
            project,
            stats["patterns_found"],
            stats["new"],
            stats["updated"],
            stats["deprecated"],
        )
        return stats

    async def _deprecate_contradicted(
        self,
        conn: asyncpg.Connection,
        existing: list[asyncpg.Record],
        new_trigger: str,
        new_resolution: str,
    ) -> int:
        """Deprecate existing patterns that contradict the new one.

        A contradiction is: same trigger keywords (>50% overlap) but a
        different resolution. The old pattern is marked ``deprecated``
        rather than deleted (Art. IV Sec. 4 — archive, don't delete).

        Returns the number of deprecated patterns.
        """
        if not new_resolution:
            return 0

        new_trigger_words = set(new_trigger.lower().split(" | "))
        deprecated = 0

        for row in existing:
            if row.get("pattern_type") == "deprecated":
                continue  # already deprecated
            old_trigger = row.get("trigger_pattern", "")
            old_resolution = row.get("resolution_pattern", "")
            if not old_trigger or not old_resolution:
                continue
            # Check trigger similarity (>50% keyword overlap)
            old_words = set(old_trigger.lower().split(" | "))
            if not old_words or not new_trigger_words:
                continue
            overlap = old_words & new_trigger_words
            overlap_ratio = len(overlap) / min(len(old_words), len(new_trigger_words))
            if overlap_ratio <= 0.5:
                continue
            # Same trigger, different resolution → contradiction
            if old_resolution.strip().lower() != new_resolution.strip().lower():
                try:
                    await conn.execute(_DEPRECATE_PATTERN_SQL, row["id"])
                    deprecated += 1
                    logger.info(
                        "consolidate: deprecated pattern #%d (trigger overlap %.0f%%, "
                        "resolution changed: %r → %r)",
                        row["id"],
                        overlap_ratio * 100,
                        old_resolution[:50],
                        new_resolution[:50],
                    )
                except Exception:
                    logger.warning(
                        "consolidate: failed to deprecate pattern #%d",
                        row["id"],
                        exc_info=True,
                    )

        return deprecated

    async def consolidate_all(self) -> dict[str, dict[str, int]]:
        """Consolidate all projects found in the vault collection.

        Returns:
            Dict mapping project name to its consolidation stats.
        """
        client = await self._get_qdrant()
        projects = await self._list_projects(client)

        results: dict[str, dict[str, int]] = {}
        for project in sorted(projects):
            try:
                results[project] = await self.consolidate_project(project)
            except Exception:
                logger.warning("consolidate_all: failed for %s", project, exc_info=True)
                results[project] = {"patterns_found": 0, "new": 0, "updated": 0}

        return results

    async def close(self) -> None:
        """Clean up connections."""
        if self._conn and not self._conn.is_closed():
            await self._conn.close()
            self._conn = None
        if self._qdrant:
            await self._qdrant.close()
            self._qdrant = None

    # -- internal helpers --

    async def _scroll_project(
        self,
        client: AsyncQdrantClient,
        project: str,
    ) -> list[dict[str, Any]]:
        """Scroll all vault points for a given project."""
        points: list[dict[str, Any]] = []
        offset = None
        project_filter = Filter(
            must=[
                FieldCondition(key="project", match=MatchValue(value=project)),
            ]
        )

        while True:
            results, next_offset = await client.scroll(
                collection_name=VAULT_COLLECTION,
                scroll_filter=project_filter,
                offset=offset,
                limit=SCROLL_BATCH,
                with_payload=True,
                with_vectors=True,
            )
            if not results:
                break

            for point in results:
                payload = point.payload or {}
                points.append(
                    {
                        "id": point.id,
                        "vector": list(point.vector) if point.vector else [],
                        "pg_id": payload.get("pg_id"),
                        "summary": payload.get("summary", ""),
                        "outcome": payload.get("outcome", ""),
                        "memory_type": payload.get("memory_type", ""),
                        "created_at": payload.get("created_at", ""),
                    }
                )

            if next_offset is None:
                break
            offset = next_offset

        return points

    async def _list_projects(self, client: AsyncQdrantClient) -> set[str]:
        """Discover all unique project names in the vault collection."""
        projects: set[str] = set()
        offset = None

        while True:
            results, next_offset = await client.scroll(
                collection_name=VAULT_COLLECTION,
                offset=offset,
                limit=SCROLL_BATCH,
                with_payload=True,
                with_vectors=False,
            )
            if not results:
                break

            for point in results:
                proj = (point.payload or {}).get("project")
                if proj:
                    projects.add(proj)

            if next_offset is None:
                break
            offset = next_offset

        return projects

    def _cluster_points(
        self,
        points: list[dict[str, Any]],
    ) -> list[list[dict[str, Any]]]:
        """Greedy clustering by cosine similarity.

        Each point is assigned to the first cluster whose centroid
        has similarity >= threshold, or starts a new cluster.
        """
        clusters: list[list[dict[str, Any]]] = []

        for point in points:
            vec = point.get("vector", [])
            if not vec:
                continue

            placed = False
            for cluster in clusters:
                centroid_vec = cluster[0].get("vector", [])
                if centroid_vec and _cosine_similarity(vec, centroid_vec) >= SIMILARITY_THRESHOLD:
                    cluster.append(point)
                    placed = True
                    break

            if not placed:
                clusters.append([point])

        return clusters


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Compute cosine similarity between two vectors."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(x * x for x in b) ** 0.5
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


# ── Date normalization ────────────────────────────────────────────────
# Inspired by Claude Code's consolidation prompt: "convert relative dates
# to absolute dates so the memory remains interpretable after time passes."

_RELATIVE_DATE_PATTERNS: list[tuple[re.Pattern[str], int]] = [
    (re.compile(r"\btoday\b", re.IGNORECASE), 0),
    (re.compile(r"\byesterday\b", re.IGNORECASE), -1),
    (re.compile(r"\btomorrow\b", re.IGNORECASE), 1),
    (re.compile(r"\blast\s+week\b", re.IGNORECASE), -7),
    (re.compile(r"\blast\s+month\b", re.IGNORECASE), -30),
]


def _normalize_dates(text: str) -> str:
    """Replace relative date references with absolute dates.

    Converts "today", "yesterday", "last week", etc. to ISO dates
    so patterns remain meaningful long after they were created.
    """
    if not text:
        return text
    now = datetime.now(timezone.utc)
    result = text
    for pattern, delta_days in _RELATIVE_DATE_PATTERNS:
        target = now + timedelta(days=delta_days)
        iso_date = target.strftime("%Y-%m-%d")
        result = pattern.sub(iso_date, result)
    return result


def _extract_trigger(cluster: list[dict[str, Any]]) -> str:
    """Extract a trigger pattern from clustered memories.

    Uses the most common words across summaries as the trigger pattern.
    """
    word_counts: Counter[str] = Counter()
    for point in cluster:
        summary = point.get("summary", "")
        words = summary.lower().split()
        # Skip very short/common words
        meaningful = [w for w in words if len(w) > 3]
        word_counts.update(meaningful)

    # Take top 8 most common meaningful words
    common = [word for word, _ in word_counts.most_common(8)]
    if not common:
        return cluster[0].get("summary", "unknown trigger")[:200]
    return " | ".join(common)


def _extract_resolution(cluster: list[dict[str, Any]]) -> str:
    """Extract the most common outcome from the cluster."""
    outcomes: Counter[str] = Counter()
    for point in cluster:
        outcome = point.get("outcome", "").strip()
        if outcome:
            outcomes[outcome] += 1

    if not outcomes:
        return ""
    return outcomes.most_common(1)[0][0]


def _extract_source_ids(cluster: list[dict[str, Any]]) -> set[int]:
    """Extract PostgreSQL memory IDs from cluster points."""
    ids: set[int] = set()
    for point in cluster:
        pg_id = point.get("pg_id")
        if pg_id is not None:
            ids.add(int(pg_id))
    return ids


def _find_overlapping_pattern(
    source_ids: set[int],
    existing: list[asyncpg.Record],
) -> asyncpg.Record | None:
    """Find an existing pattern with >50% source ID overlap."""
    if not source_ids:
        return None

    for row in existing:
        existing_ids = set(row["source_memory_ids"] or [])
        if not existing_ids:
            continue
        overlap = source_ids & existing_ids
        # >50% overlap with either set means it's the same pattern
        if len(overlap) > len(existing_ids) * 0.5 or len(overlap) > len(source_ids) * 0.5:
            return row

    return None
