# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Cluster and consolidate old memories into pattern summaries.

Groups semantically similar memories using Qdrant vectors, then merges
large clusters into a single "pattern" memory and tracks originals in
the ``memory_consolidation`` table.
"""

import logging
from dataclasses import dataclass
from typing import Any

from maude.db import LazyPool
from maude.memory.store import MemoryStore

logger = logging.getLogger(__name__)


@dataclass
class ConsolidationResult:
    """Summary of a consolidation run."""

    memories_scanned: int = 0
    clusters_found: int = 0
    patterns_created: int = 0
    memories_consolidated: int = 0


# SQL for fetching unconsolidated memories older than N days
_FETCH_OLD_SQL = """
    SELECT am.id, am.summary, am.memory_type, am.outcome, am.trigger
    FROM agent_memory am
    LEFT JOIN memory_consolidation mc ON mc.memory_id = am.id
    WHERE am.project = $1
      AND am.created_at < now() - make_interval(days => $2)
      AND mc.memory_id IS NULL
    ORDER BY am.created_at
"""

# Track which memories were consolidated into which pattern
_INSERT_CONSOLIDATION_SQL = """
    INSERT INTO memory_consolidation (memory_id, consolidated_into, created_at)
    VALUES ($1, $2, now())
"""


class MemoryConsolidator:
    """Cluster old memories by semantic similarity and merge into patterns.

    Args:
        project: Project identifier (e.g. "my-service").
    """

    def __init__(self, project: str) -> None:
        self.project = project
        self._store = MemoryStore(project=project)
        self._db = LazyPool(database="agent")

    async def consolidate(
        self,
        min_age_days: int = 7,
        min_cluster_size: int = 5,
    ) -> ConsolidationResult:
        """Scan old memories, cluster by similarity, merge large groups.

        Args:
            min_age_days: Only consider memories older than this.
            min_cluster_size: Minimum members for a cluster to be merged.

        Returns:
            ConsolidationResult with stats.
        """
        result = ConsolidationResult()

        pool = await self._db.get()
        if pool is None:
            return result

        try:
            rows = await pool.fetch(_FETCH_OLD_SQL, self.project, min_age_days)
        except Exception:
            logger.warning("MemoryConsolidator: fetch failed", exc_info=True)
            return result

        if not rows:
            return result

        result.memories_scanned = len(rows)

        # Get embeddings for each memory
        memory_vectors: list[tuple[dict[str, Any], list[float]]] = []
        for row in rows:
            vec = await self._store._embed(row["summary"])
            if vec:
                memory_vectors.append((dict(row), vec))

        if not memory_vectors:
            return result

        # Cluster by cosine similarity
        clusters = _cluster_vectors(memory_vectors, threshold=0.85)
        result.clusters_found = len([c for c in clusters if len(c) >= min_cluster_size])

        for cluster in clusters:
            if len(cluster) < min_cluster_size:
                continue

            # Create a merged pattern memory
            summaries = [m["summary"] for m, _ in cluster]
            merged_summary = _merge_summaries(summaries)
            types = {m["memory_type"] for m, _ in cluster}
            merged_type = "pattern"

            pattern_id = await self._store.store_memory(
                project=self.project,
                memory_type=merged_type,
                summary=merged_summary,
                context={"consolidated_from": len(cluster), "original_types": sorted(types)},
                trigger="consolidation",
                reasoning=f"Merged {len(cluster)} similar memories",
                outcome="consolidated",
            )

            if pattern_id is None:
                continue

            # Embed the new pattern
            await self._store.embed_and_store(
                memory_id=pattern_id,
                summary=merged_summary,
                memory_type=merged_type,
                outcome="consolidated",
            )

            # Track originals in consolidation table
            for mem, _ in cluster:
                try:
                    await pool.execute(_INSERT_CONSOLIDATION_SQL, mem["id"], pattern_id)
                except Exception:
                    logger.warning(
                        "MemoryConsolidator: failed to track memory %d",
                        mem["id"],
                        exc_info=True,
                    )

            result.patterns_created += 1
            result.memories_consolidated += len(cluster)

        return result

    async def close(self) -> None:
        """Clean up connections."""
        await self._db.close()
        await self._store.close()


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Compute cosine similarity between two vectors."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(x * x for x in b) ** 0.5
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def _cluster_vectors(
    items: list[tuple[dict[str, Any], list[float]]],
    threshold: float = 0.85,
) -> list[list[tuple[dict[str, Any], list[float]]]]:
    """Simple greedy clustering by cosine similarity.

    Each item is assigned to the first cluster whose centroid (first item)
    has similarity >= threshold, or starts a new cluster.
    """
    clusters: list[list[tuple[dict[str, Any], list[float]]]] = []

    for item in items:
        _, vec = item
        placed = False
        for cluster in clusters:
            centroid_vec = cluster[0][1]
            if _cosine_similarity(vec, centroid_vec) >= threshold:
                cluster.append(item)
                placed = True
                break
        if not placed:
            clusters.append([item])

    return clusters


def _merge_summaries(summaries: list[str]) -> str:
    """Merge multiple memory summaries into a single pattern summary."""
    if len(summaries) == 1:
        return summaries[0]
    # Take unique summaries, dedup, join
    seen: set[str] = set()
    unique: list[str] = []
    for s in summaries:
        if s not in seen:
            seen.add(s)
            unique.append(s)
    prefix = f"Pattern from {len(summaries)} occurrences: "
    # Show up to 3 unique examples
    examples = "; ".join(unique[:3])
    if len(unique) > 3:
        examples += f" (and {len(unique) - 3} more)"
    return prefix + examples
