# Maude Local Store — SQLite-backed sovereign memory for Rooms
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Created: 2026-03-05
"""Local SQLite memory store for Room sovereignty.

Provides persistent local storage at /var/lib/maude-agents/{project}/memory.db.
Every Room gets its own SQLite database that survives PG/Qdrant outages.

Tier hierarchy:
    Tier 1:   Markdown files (.maude/knowledge/) — identity, static knowledge
    Tier 1.5: SQLite (this module) — structured local memory
    Tier 2:   PostgreSQL — shared structured memory
    Tier 3:   Qdrant — semantic vector search

Design principles:
    - Write local FIRST, promote to PG/Qdrant via SyncWorker
    - FTS5 for keyword search when Qdrant is unavailable
    - WAL mode for concurrent reads during sync
    - Zero external deps (sqlite3 is stdlib, FTS5 ships with Ubuntu 24.04)
    - asyncio.to_thread() for non-blocking operations
"""

import asyncio
import json
import logging
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

_SCHEMA_SQL = """\
CREATE TABLE IF NOT EXISTS memories (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    pg_id           INTEGER,
    memory_type     TEXT NOT NULL,
    trigger         TEXT DEFAULT '',
    context         TEXT DEFAULT '{}',
    reasoning       TEXT DEFAULT '',
    actions_taken   TEXT DEFAULT '[]',
    outcome         TEXT DEFAULT '',
    summary         TEXT NOT NULL,
    tokens_used     INTEGER DEFAULT 0,
    model           TEXT DEFAULT '',
    root_cause      TEXT DEFAULT '',
    created_at      TEXT NOT NULL,
    synced_at       TEXT,
    embedded_at     TEXT,
    tier_origin     INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS sync_queue (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id       INTEGER NOT NULL REFERENCES memories(id),
    target_tier     INTEGER NOT NULL,
    status          TEXT DEFAULT 'pending',
    attempts        INTEGER DEFAULT 0,
    last_attempt    TEXT,
    created_at      TEXT NOT NULL,
    UNIQUE(memory_id, target_tier)
);

CREATE TABLE IF NOT EXISTS sync_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS local_audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    tool       TEXT NOT NULL,
    caller     TEXT DEFAULT '',
    action     TEXT NOT NULL,
    detail     TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS relay_outbox (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    to_room       TEXT NOT NULL,
    subject       TEXT NOT NULL DEFAULT '',
    body          TEXT NOT NULL DEFAULT '',
    priority      INTEGER NOT NULL DEFAULT 0,
    status        TEXT NOT NULL DEFAULT 'pending',
    pg_task_id    INTEGER,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_attempt  TEXT,
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_memories_type_created
    ON memories(memory_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_memories_pg_id
    ON memories(pg_id) WHERE pg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sync_queue_status
    ON sync_queue(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_relay_outbox_status
    ON relay_outbox(status) WHERE status = 'pending';
"""

_FTS_SCHEMA_SQL = """\
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
    summary, reasoning, root_cause,
    content='memories', content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, summary, reasoning, root_cause)
    VALUES (new.id, new.summary, new.reasoning, new.root_cause);
END;

CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, summary, reasoning, root_cause)
    VALUES ('delete', old.id, old.summary, old.reasoning, old.root_cause);
END;

CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, summary, reasoning, root_cause)
    VALUES ('delete', old.id, old.summary, old.reasoning, old.root_cause);
    INSERT INTO memories_fts(rowid, summary, reasoning, root_cause)
    VALUES (new.id, new.summary, new.reasoning, new.root_cause);
END;
"""

_PATTERN_SQL = """\
SELECT
    substr(summary, 1, 100) AS signature,
    outcome,
    root_cause,
    COUNT(*) AS frequency,
    MAX(created_at) AS last_seen,
    GROUP_CONCAT(DISTINCT json_extract(actions_taken, '$[0].action')) AS actions
FROM memories
WHERE memory_type NOT IN ('check')
  AND created_at > datetime('now', ?)
GROUP BY signature, outcome, root_cause
HAVING COUNT(*) >= ?
ORDER BY frequency DESC
"""


class LocalStore:
    """SQLite-backed local memory for a Room.

    Each Room gets its own database at /var/lib/maude-agents/{project}/memory.db.
    All operations run in a thread executor to avoid blocking the event loop.
    """

    def __init__(self, project: str, db_path: Path | None = None) -> None:
        self.project = project
        self.db_path = db_path or Path(f"/var/lib/maude-agents/{project}/memory.db")
        self._conn: sqlite3.Connection | None = None
        self._initialized = False
        self._has_fts = False

    def _get_conn(self) -> sqlite3.Connection:
        """Get or create SQLite connection (called from thread)."""
        if self._conn is None:
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
            self._conn = sqlite3.connect(
                str(self.db_path),
                timeout=10,
                check_same_thread=False,
            )
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA synchronous=NORMAL")
            self._conn.execute("PRAGMA foreign_keys=ON")
        return self._conn

    async def initialize(self) -> None:
        """Create tables and indexes if they don't exist."""
        if self._initialized:
            return

        def _init() -> bool:
            conn = self._get_conn()
            conn.executescript(_SCHEMA_SQL)
            has_fts = False
            try:
                conn.executescript(_FTS_SCHEMA_SQL)
                has_fts = True
            except sqlite3.OperationalError:
                logger.warning("LocalStore: FTS5 unavailable — keyword search disabled")
            conn.commit()
            return has_fts

        self._has_fts = await asyncio.to_thread(_init)
        self._initialized = True
        logger.info("LocalStore: initialized %s (fts=%s)", self.db_path, self._has_fts)

    async def store(
        self,
        memory_type: str,
        summary: str,
        *,
        trigger: str = "",
        context: dict[str, Any] | None = None,
        reasoning: str = "",
        actions_taken: list[dict[str, Any]] | None = None,
        outcome: str = "",
        tokens_used: int = 0,
        model: str = "",
        root_cause: str = "",
        pg_id: int | None = None,
        tier_origin: int = 1,
        enqueue_sync: bool = True,
    ) -> int:
        """Store a memory locally. Returns the local row ID."""
        await self.initialize()
        now = datetime.now(timezone.utc).isoformat()

        def _store() -> int:
            conn = self._get_conn()
            cursor = conn.execute(
                """INSERT INTO memories
                    (pg_id, memory_type, trigger, context, reasoning,
                     actions_taken, outcome, summary, tokens_used, model,
                     root_cause, created_at, tier_origin)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    pg_id,
                    memory_type,
                    trigger,
                    json.dumps(context or {}, default=str),
                    reasoning,
                    json.dumps(actions_taken or [], default=str),
                    outcome,
                    summary,
                    tokens_used,
                    model,
                    root_cause,
                    now,
                    tier_origin,
                ),
            )
            local_id = cursor.lastrowid
            if local_id is None:
                raise RuntimeError("INSERT into memories returned no lastrowid")

            if enqueue_sync and tier_origin == 1:
                for target_tier in (3, 4):  # 3=PG, 4=Qdrant
                    conn.execute(
                        """INSERT OR IGNORE INTO sync_queue
                            (memory_id, target_tier, created_at)
                           VALUES (?, ?, ?)""",
                        (local_id, target_tier, now),
                    )
            conn.commit()
            return local_id

        return await asyncio.to_thread(_store)

    async def recall_recent(
        self,
        memory_type: str | None = None,
        limit: int = 10,
    ) -> list[dict[str, Any]]:
        """Recall recent memories from local SQLite."""
        await self.initialize()

        def _recall() -> list[dict[str, Any]]:
            conn = self._get_conn()
            if memory_type:
                rows = conn.execute(
                    "SELECT * FROM memories WHERE memory_type = ? ORDER BY created_at DESC LIMIT ?",
                    (memory_type, limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM memories ORDER BY created_at DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            return [dict(r) for r in rows]

        return await asyncio.to_thread(_recall)

    async def recall_by_id(self, local_id: int) -> dict[str, Any] | None:
        """Recall a single memory by local ID."""
        await self.initialize()

        def _recall() -> dict[str, Any] | None:
            conn = self._get_conn()
            row = conn.execute(
                "SELECT * FROM memories WHERE id = ?",
                (local_id,),
            ).fetchone()
            return dict(row) if row else None

        return await asyncio.to_thread(_recall)

    async def search_fts(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        """Full-text search across summaries, reasoning, root_cause.

        Falls back to LIKE search if FTS5 is unavailable.
        """
        await self.initialize()

        def _search() -> list[dict[str, Any]]:
            conn = self._get_conn()
            if self._has_fts:
                try:
                    rows = conn.execute(
                        "SELECT m.*, rank FROM memories_fts fts "
                        "JOIN memories m ON m.id = fts.rowid "
                        "WHERE memories_fts MATCH ? "
                        "ORDER BY rank LIMIT ?",
                        (query, limit),
                    ).fetchall()
                    return [dict(r) for r in rows]
                except sqlite3.OperationalError:
                    pass  # fall through to LIKE

            like_q = f"%{query}%"
            rows = conn.execute(
                "SELECT * FROM memories "
                "WHERE summary LIKE ? OR reasoning LIKE ? OR root_cause LIKE ? "
                "ORDER BY created_at DESC LIMIT ?",
                (like_q, like_q, like_q, limit),
            ).fetchall()
            return [dict(r) for r in rows]

        return await asyncio.to_thread(_search)

    async def detect_patterns(
        self,
        window_days: int = 7,
        min_frequency: int = 3,
    ) -> list[dict[str, Any]]:
        """Detect repeated patterns from local memory."""
        await self.initialize()

        def _detect() -> list[dict[str, Any]]:
            conn = self._get_conn()
            rows = conn.execute(
                _PATTERN_SQL,
                (f"-{window_days} days", min_frequency),
            ).fetchall()
            return [dict(r) for r in rows]

        return await asyncio.to_thread(_detect)

    async def find_past_fix(
        self,
        root_cause: str,
        min_success_rate: float = 0.75,
        min_occurrences: int = 3,
    ) -> dict[str, Any] | None:
        """Find a past successful fix for a given root cause.

        Queries local history for incidents with the same root_cause and
        returns the action with the highest success rate, if it meets
        the confidence thresholds.
        """
        await self.initialize()

        def _find() -> dict[str, Any] | None:
            conn = self._get_conn()
            rows = conn.execute(
                """SELECT
                       root_cause,
                       json_extract(actions_taken, '$[0].action') AS action,
                       COUNT(*) AS total,
                       SUM(CASE WHEN outcome = 'resolved' THEN 1 ELSE 0 END) AS successes
                   FROM memories
                   WHERE root_cause = ? AND memory_type = 'incident'
                     AND actions_taken != '[]'
                   GROUP BY root_cause, action
                   HAVING COUNT(*) >= ?
                   ORDER BY successes DESC
                   LIMIT 1""",
                (root_cause, min_occurrences),
            ).fetchall()

            for row in rows:
                r = dict(row)
                total = r["total"] or 0
                successes = r["successes"] or 0
                success_rate = successes / total if total > 0 else 0
                if success_rate >= min_success_rate:
                    return {
                        "root_cause": r["root_cause"],
                        "action": r["action"],
                        "success_rate": success_rate,
                        "occurrences": total,
                    }
            return None

        return await asyncio.to_thread(_find)

    async def get_pending_sync(self, limit: int = 50) -> list[dict[str, Any]]:
        """Get pending sync queue entries with full memory data."""
        await self.initialize()

        def _get() -> list[dict[str, Any]]:
            conn = self._get_conn()
            rows = conn.execute(
                """SELECT sq.*, m.summary, m.memory_type, m.outcome,
                          m.trigger, m.context, m.reasoning, m.actions_taken,
                          m.tokens_used, m.model, m.root_cause,
                          m.created_at AS mem_created_at
                   FROM sync_queue sq
                   JOIN memories m ON m.id = sq.memory_id
                   WHERE sq.status = 'pending' AND sq.attempts < 5
                   ORDER BY sq.created_at ASC
                   LIMIT ?""",
                (limit,),
            ).fetchall()
            return [dict(r) for r in rows]

        return await asyncio.to_thread(_get)

    async def mark_synced(
        self,
        memory_id: int,
        target_tier: int,
        pg_id: int | None = None,
    ) -> None:
        """Mark a sync queue entry as completed."""
        now = datetime.now(timezone.utc).isoformat()

        def _mark() -> None:
            conn = self._get_conn()
            conn.execute(
                "UPDATE sync_queue SET status = 'completed', last_attempt = ? "
                "WHERE memory_id = ? AND target_tier = ?",
                (now, memory_id, target_tier),
            )
            if pg_id is not None:
                conn.execute(
                    "UPDATE memories SET pg_id = ?, synced_at = ? WHERE id = ?",
                    (pg_id, now, memory_id),
                )
            if target_tier == 4:  # Qdrant
                conn.execute(
                    "UPDATE memories SET embedded_at = ? WHERE id = ?",
                    (now, memory_id),
                )
            conn.commit()

        await asyncio.to_thread(_mark)

    async def mark_sync_failed(self, memory_id: int, target_tier: int) -> None:
        """Increment attempt count on a failed sync."""
        now = datetime.now(timezone.utc).isoformat()

        def _mark() -> None:
            conn = self._get_conn()
            conn.execute(
                "UPDATE sync_queue "
                "SET attempts = attempts + 1, last_attempt = ?, "
                "    status = CASE WHEN attempts >= 4 THEN 'failed' ELSE 'pending' END "
                "WHERE memory_id = ? AND target_tier = ?",
                (now, memory_id, target_tier),
            )
            conn.commit()

        await asyncio.to_thread(_mark)

    async def warm_from_pg(self, rows: list[dict[str, Any]]) -> int:
        """Populate local SQLite from PostgreSQL records (sync-down).

        Skips rows already present (matched by pg_id). Marks them as
        tier_origin=3 to prevent circular sync-up.
        """
        await self.initialize()

        def _warm() -> int:
            conn = self._get_conn()
            count = 0
            for row in rows:
                existing = conn.execute(
                    "SELECT 1 FROM memories WHERE pg_id = ?",
                    (row["id"],),
                ).fetchone()
                if existing:
                    continue
                context_val = row.get("context", {})
                if isinstance(context_val, dict):
                    context_val = json.dumps(context_val, default=str)
                actions_val = row.get("actions_taken", [])
                if isinstance(actions_val, list):
                    actions_val = json.dumps(actions_val, default=str)
                conn.execute(
                    """INSERT INTO memories
                       (pg_id, memory_type, trigger, context, reasoning,
                        actions_taken, outcome, summary, tokens_used, model,
                        created_at, synced_at, tier_origin)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 3)""",
                    (
                        row["id"],
                        row.get("memory_type", ""),
                        row.get("trigger", ""),
                        context_val,
                        row.get("reasoning", ""),
                        actions_val,
                        row.get("outcome", ""),
                        row.get("summary", ""),
                        (row.get("tokens_used") or 0),
                        row.get("model", ""),
                        str(row.get("created_at", "")),
                        datetime.now(timezone.utc).isoformat(),
                    ),
                )
                count += 1
            conn.commit()
            return count

        result = await asyncio.to_thread(_warm)
        if result:
            logger.info("LocalStore: warmed %d memories from PG for %s", result, self.project)
        return result

    async def audit_log(
        self,
        tool: str,
        action: str,
        *,
        caller: str = "",
        detail: str = "",
    ) -> None:
        """Write to local audit log."""

        def _log() -> None:
            conn = self._get_conn()
            conn.execute(
                "INSERT INTO local_audit_log (tool, caller, action, detail) VALUES (?, ?, ?, ?)",
                (tool, caller, action, detail),
            )
            conn.commit()

        await asyncio.to_thread(_log)

    async def stats(self) -> dict[str, Any]:
        """Return local store statistics."""
        await self.initialize()

        def _stats() -> dict[str, Any]:
            conn = self._get_conn()
            total = conn.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
            unsynced = conn.execute(
                "SELECT COUNT(*) FROM sync_queue WHERE status = 'pending'",
            ).fetchone()[0]
            failed = conn.execute(
                "SELECT COUNT(*) FROM sync_queue WHERE status = 'failed'",
            ).fetchone()[0]
            by_type = conn.execute(
                "SELECT memory_type, COUNT(*) as cnt FROM memories GROUP BY memory_type",
            ).fetchall()
            return {
                "total_memories": total,
                "pending_sync": unsynced,
                "failed_sync": failed,
                "by_type": {r["memory_type"]: r["cnt"] for r in by_type},
                "db_path": str(self.db_path),
            }

        return await asyncio.to_thread(_stats)

    async def prune(self) -> dict[str, int]:
        """Delete old completed/failed queue entries and audit logs.

        Retention:
        - sync_queue completed/failed: 7 days
        - relay_outbox synced/failed: 7 days
        - local_audit_log: 30 days

        Returns dict with counts of deleted rows per table.
        """
        await self.initialize()

        def _prune() -> dict[str, int]:
            conn = self._get_conn()
            counts: dict[str, int] = {}

            cursor = conn.execute(
                "DELETE FROM sync_queue "
                "WHERE status IN ('completed', 'failed') "
                "AND created_at < datetime('now', '-7 days')",
            )
            counts["sync_queue"] = cursor.rowcount

            cursor = conn.execute(
                "DELETE FROM local_audit_log WHERE created_at < datetime('now', '-30 days')",
            )
            counts["local_audit_log"] = cursor.rowcount

            cursor = conn.execute(
                "DELETE FROM relay_outbox "
                "WHERE status IN ('synced', 'failed') "
                "AND created_at < datetime('now', '-7 days')",
            )
            counts["relay_outbox"] = cursor.rowcount

            conn.commit()
            return counts

        return await asyncio.to_thread(_prune)

    async def close(self) -> None:
        """Close the SQLite connection."""
        if self._conn:
            conn = self._conn
            self._conn = None

            def _close() -> None:
                conn.close()

            await asyncio.to_thread(_close)
