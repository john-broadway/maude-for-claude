# Maude Memory Snapshot — export/import room memory for fleet cloning.
# Version: 1.0.0
# Created: 2026-04-02 16:20 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Export and import room memory state for fleet cloning and disaster recovery.

Exports a room's memory as a JSON bundle containing:
- PostgreSQL memories (agent_memory rows)
- Pattern library (memory_patterns rows)

Import re-inserts with namespace remapping (source project -> target project).
Knowledge .md files are handled by ``deploy-fleet.sh`` rsync and are NOT
included in the snapshot (they're in git, not PG).

Usage::

    snapshot = MemorySnapshot(db_host="192.0.2.30")
    bundle = await snapshot.export_project("example-scada")
    # Transfer bundle to target site...
    stats = await snapshot.import_project(bundle, target_project="example-scada-b")
"""

from __future__ import annotations

import json
import logging
from datetime import datetime
from datetime import timezone as tz
from typing import Any

from maude.daemon.common import resolve_infra_hosts
from maude.db import PoolRegistry

logger = logging.getLogger(__name__)

_EXPORT_MEMORIES_SQL = """
SELECT id, project, memory_type, trigger, context, reasoning,
       actions_taken, outcome, summary, tokens_used, model,
       root_cause, created_at
FROM agent_memory
WHERE project = $1
ORDER BY created_at ASC
"""

_EXPORT_PATTERNS_SQL = """
SELECT id, project, pattern_type, trigger_pattern, resolution_pattern,
       frequency, source_memory_ids, created_at, updated_at
FROM memory_patterns
WHERE project = $1
ORDER BY id ASC
"""

_IMPORT_MEMORY_SQL = """
INSERT INTO agent_memory
    (project, memory_type, trigger, context, reasoning,
     actions_taken, outcome, summary, tokens_used, model, root_cause)
VALUES ($1, $2, $3, $4::jsonb, $5, $6::jsonb, $7, $8, $9, $10, $11)
RETURNING id
"""

_IMPORT_PATTERN_SQL = """
INSERT INTO memory_patterns
    (project, pattern_type, trigger_pattern, resolution_pattern,
     frequency, source_memory_ids)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING id
"""

SNAPSHOT_VERSION = 1


class MemorySnapshot:
    """Export and import room memory snapshots.

    Args:
        db_host: PostgreSQL host. Defaults to resolved infra host.
        database: Database name. Defaults to "agent".
    """

    def __init__(
        self,
        db_host: str = "",
        database: str = "agent",
    ) -> None:
        self.db_host = db_host or resolve_infra_hosts()["db"]
        self._db = PoolRegistry.get(database=database, db_host=self.db_host)

    async def export_project(self, project: str) -> dict[str, Any]:
        """Export all memories and patterns for a project as a JSON-serializable dict.

        Returns a snapshot bundle with version, metadata, memories, and patterns.
        """
        pool = await self._db.get()
        if pool is None:
            raise RuntimeError("PostgreSQL unavailable — cannot export")

        # Export memories
        memory_rows = await pool.fetch(_EXPORT_MEMORIES_SQL, project)
        memories = []
        for row in memory_rows:
            context = row["context"]
            if isinstance(context, str):
                context = json.loads(context)
            actions = row["actions_taken"]
            if isinstance(actions, str):
                actions = json.loads(actions)
            memories.append(
                {
                    "original_id": row["id"],
                    "memory_type": row["memory_type"],
                    "trigger": row["trigger"] or "",
                    "context": context if isinstance(context, dict) else {},
                    "reasoning": row["reasoning"] or "",
                    "actions_taken": actions if isinstance(actions, list) else [],
                    "outcome": row["outcome"] or "",
                    "summary": row["summary"],
                    "tokens_used": row["tokens_used"] or 0,
                    "model": row["model"] or "",
                    "root_cause": row["root_cause"] or "",
                    "created_at": row["created_at"].isoformat() if row["created_at"] else None,
                }
            )

        # Export patterns
        pattern_rows = await pool.fetch(_EXPORT_PATTERNS_SQL, project)
        patterns = []
        for row in pattern_rows:
            patterns.append(
                {
                    "original_id": row["id"],
                    "pattern_type": row["pattern_type"] or "recurring",
                    "trigger_pattern": row["trigger_pattern"],
                    "resolution_pattern": row["resolution_pattern"] or "",
                    "frequency": row["frequency"] or 1,
                    "source_memory_ids": list(row["source_memory_ids"] or []),
                    "created_at": row["created_at"].isoformat() if row["created_at"] else None,
                }
            )

        bundle: dict[str, Any] = {
            "version": SNAPSHOT_VERSION,
            "source_project": project,
            "exported_at": datetime.now(tz.utc).isoformat(),
            "memory_count": len(memories),
            "pattern_count": len(patterns),
            "memories": memories,
            "patterns": patterns,
        }

        logger.info(
            "Snapshot: exported %d memories + %d patterns for %s",
            len(memories),
            len(patterns),
            project,
        )
        return bundle

    async def import_project(
        self,
        bundle: dict[str, Any],
        target_project: str,
    ) -> dict[str, int]:
        """Import a snapshot bundle into a target project.

        Remaps the project name from source to target. Does NOT import
        Qdrant embeddings — use ``MemoryStore.backfill_embeddings()``
        after import to regenerate vectors.

        Returns stats: memories_imported, patterns_imported, errors.
        """
        if bundle.get("version") != SNAPSHOT_VERSION:
            got = bundle.get("version")
            raise ValueError(f"Unsupported snapshot version: {got} (expected {SNAPSHOT_VERSION})")

        pool = await self._db.get()
        if pool is None:
            raise RuntimeError("PostgreSQL unavailable — cannot import")

        stats = {"memories_imported": 0, "patterns_imported": 0, "errors": 0}

        # Import memories — build ID mapping (old_id -> new_id)
        id_map: dict[int, int] = {}
        for mem in bundle.get("memories", []):
            try:
                new_id = await pool.fetchval(
                    _IMPORT_MEMORY_SQL,
                    target_project,
                    mem.get("memory_type", ""),
                    mem.get("trigger", ""),
                    json.dumps(mem.get("context") or {}, default=str),
                    mem.get("reasoning", ""),
                    json.dumps(mem.get("actions_taken") or [], default=str),
                    mem.get("outcome", ""),
                    mem.get("summary", ""),
                    mem.get("tokens_used", 0),
                    mem.get("model", ""),
                    mem.get("root_cause", ""),
                )
                old_id = mem.get("original_id")
                if old_id is not None and new_id is not None:
                    id_map[old_id] = new_id
                stats["memories_imported"] += 1
            except Exception:
                stats["errors"] += 1
                logger.debug(
                    "Snapshot: failed to import memory %s",
                    mem.get("original_id"),
                    exc_info=True,
                )

        # Import patterns — remap source_memory_ids using id_map
        for pat in bundle.get("patterns", []):
            try:
                old_source_ids = pat.get("source_memory_ids", [])
                new_source_ids = [id_map.get(oid, oid) for oid in old_source_ids]
                await pool.fetchval(
                    _IMPORT_PATTERN_SQL,
                    target_project,
                    pat.get("pattern_type", "recurring"),
                    pat.get("trigger_pattern", ""),
                    pat.get("resolution_pattern", ""),
                    pat.get("frequency", 1),
                    new_source_ids,
                )
                stats["patterns_imported"] += 1
            except Exception:
                stats["errors"] += 1
                logger.debug(
                    "Snapshot: failed to import pattern %s",
                    pat.get("original_id"),
                    exc_info=True,
                )

        logger.info(
            "Snapshot: imported %d memories + %d patterns into %s (%d errors)",
            stats["memories_imported"],
            stats["patterns_imported"],
            target_project,
            stats["errors"],
        )
        return stats

    async def close(self) -> None:
        """Clean up connections."""
        await self._db.close()
