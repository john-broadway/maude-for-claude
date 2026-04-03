# Maude Sync Worker — Background memory sync SQLite ↔ PostgreSQL
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Created: 2026-03-05
"""Background sync worker for local SQLite ↔ PostgreSQL/Qdrant.

Runs as an asyncio background task alongside the health loop.
Drains the local sync_queue to PostgreSQL and Qdrant (sync-up),
and periodically pulls recent PG memories into SQLite (sync-down).

Sync-up (every 60s):   local SQLite → PostgreSQL → Qdrant
Sync-down (every 300s): PostgreSQL → local SQLite cache
Warm-from-PG (startup): populate empty SQLite on first boot
"""

import asyncio
import json
import logging
import random
from contextlib import suppress
from typing import Any

from maude.memory.local_store import LocalStore
from maude.memory.types import should_embed, should_sync_to_pg

logger = logging.getLogger(__name__)


class SyncWorker:
    """Background task that syncs local SQLite memories to PG and Qdrant."""

    def __init__(
        self,
        local_store: LocalStore,
        memory_store: Any,  # MemoryStore — avoid circular import
        project: str,
        sync_up_interval: int = 60,
        sync_down_interval: int = 300,
    ) -> None:
        self.local = local_store
        self.memory = memory_store
        self.project = project
        self.sync_up_interval = sync_up_interval
        self.sync_down_interval = sync_down_interval
        self._task: asyncio.Task[None] | None = None
        self._sync_down_counter = 0
        self._prune_counter = 0

    async def start(self) -> None:
        """Start the sync worker as a background task."""
        await self.local.initialize()
        await self._warm_if_empty()
        self._task = asyncio.create_task(
            self._loop(),
            name=f"sync-worker-{self.project}",
        )
        logger.info(
            "SyncWorker: started for %s (up=%ds, down=%ds)",
            self.project,
            self.sync_up_interval,
            self.sync_down_interval,
        )

    async def stop(self) -> None:
        """Stop the sync worker gracefully."""
        if self._task:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        logger.info("SyncWorker: stopped for %s", self.project)

    async def _loop(self) -> None:
        """Main loop — sync up frequently, sync down less often."""
        await asyncio.sleep(15 + random.uniform(0, 30))  # let services settle

        while True:
            try:
                await self._sync_up()

                self._sync_down_counter += self.sync_up_interval
                if self._sync_down_counter >= self.sync_down_interval:
                    await self._sync_down()
                    self._sync_down_counter = 0

                    # Prune every ~24 sync-down cycles (~2 hours at 300s = ~48h)
                    self._prune_counter += 1
                    if self._prune_counter >= 24:
                        self._prune_counter = 0
                        await self._prune()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("SyncWorker: loop error (non-fatal)")

            await asyncio.sleep(self.sync_up_interval)

    async def _sync_up(self) -> None:
        """Drain sync_queue → push to PG and Qdrant."""
        pending = await self.local.get_pending_sync(limit=50)
        if not pending:
            return

        pg_synced = 0
        for entry in pending:
            memory_id = entry["memory_id"]
            target_tier = entry["target_tier"]

            # Use type policies to decide whether to sync to PG/Qdrant.
            # Replaces scattered hardcoded noise filters with centralized
            # MemoryTypePolicy checks from memory.types.
            mem_type = entry.get("memory_type", "")
            outcome = entry.get("outcome", "")
            trigger = entry.get("trigger", "")
            is_health = trigger == "health_loop" or trigger.startswith("health_loop_")

            if target_tier == 3:  # PG sync
                raw_actions = entry.get("actions_taken", "[]")
                if isinstance(raw_actions, str):
                    try:
                        parsed_actions = json.loads(raw_actions)
                    except (json.JSONDecodeError, TypeError):
                        parsed_actions = []
                else:
                    parsed_actions = raw_actions if isinstance(raw_actions, list) else []
                has_actions = bool(parsed_actions)
                is_noise = (
                    not should_sync_to_pg(mem_type, outcome)
                    or (
                        mem_type == "incident"
                        and outcome in ("resolved", "failed")
                        and not has_actions
                    )
                    or (mem_type == "escalation" and outcome in ("escalated", "failed"))
                    # Health loop incidents with restart/escalation actions are
                    # already written to PG by store_memory() — SyncWorker pushing
                    # them again creates duplicates.
                    or (is_health and outcome != "remediated")
                )
                if is_noise:
                    await self.local.mark_synced(memory_id, target_tier)
                    continue

            elif target_tier == 4:  # Qdrant sync — skip if policy says no embed
                if not should_embed(mem_type, outcome):
                    await self.local.mark_synced(memory_id, target_tier)
                    continue

            try:
                if target_tier == 3:  # PostgreSQL
                    pg_id = await self._push_to_pg(entry)
                    if pg_id is not None:
                        await self.local.mark_synced(
                            memory_id,
                            target_tier,
                            pg_id=pg_id,
                        )
                        pg_synced += 1
                    else:
                        await self.local.mark_sync_failed(memory_id, target_tier)

                elif target_tier == 4:  # Qdrant
                    row = await self.local.recall_by_id(memory_id)
                    if row and row.get("pg_id"):
                        ok = await self._push_to_qdrant(row)
                        if ok:
                            await self.local.mark_synced(memory_id, target_tier)
                        else:
                            await self.local.mark_sync_failed(
                                memory_id,
                                target_tier,
                            )
                    # else: PG sync not done yet — retry next cycle

            except Exception:
                logger.warning(
                    "SyncWorker: sync-up failed for memory %d tier %d",
                    memory_id,
                    target_tier,
                    exc_info=True,
                )
                await self.local.mark_sync_failed(memory_id, target_tier)

        if pg_synced:
            logger.debug(
                "SyncWorker: synced %d memories to PG for %s",
                pg_synced,
                self.project,
            )

    async def _push_to_pg(self, entry: dict[str, Any]) -> int | None:
        """Push a local memory to PostgreSQL. Returns pg row ID or None.

        Writes directly to PG via MemoryStore._ensure_pool(), bypassing
        store_memory() to avoid re-enqueuing in SQLite (which would create
        an infinite duplication loop).
        """
        actions = entry.get("actions_taken", "[]")
        if isinstance(actions, str):
            try:
                actions = json.loads(actions)
            except (json.JSONDecodeError, TypeError):
                actions = []
        if not isinstance(actions, list):
            actions = []

        pool = await self.memory._ensure_pool()
        if pool is None:
            return None

        try:
            # INSERT_SQL is an atomic CTE that deduplicates in a single
            # statement — no race condition (#1).
            row_id = await pool.fetchval(
                self.memory.INSERT_SQL,
                self.project,
                entry.get("memory_type", ""),
                entry.get("trigger", ""),
                json.dumps(entry.get("context") or {}, default=str),
                entry.get("reasoning", ""),
                json.dumps(actions, default=str),
                entry.get("outcome", ""),
                entry.get("summary", ""),
                (entry.get("tokens_used") or 0),
                entry.get("model", ""),
                entry.get("root_cause", ""),
                None,  # conversation
            )
            return row_id
        except Exception:
            logger.warning("SyncWorker: PG insert failed", exc_info=True)
            return None

    async def _push_to_qdrant(self, row: dict[str, Any]) -> bool:
        """Embed a memory in Qdrant. Returns True on success."""
        pg_id = row.get("pg_id")
        if not pg_id:
            return False
        return await self.memory.embed_and_store(
            memory_id=pg_id,
            summary=row.get("summary", ""),
            memory_type=row.get("memory_type", "incident"),
            outcome=row.get("outcome", ""),
            root_cause=row.get("root_cause", ""),
        )

    async def _sync_down(self) -> None:
        """Pull recent PG memories into local SQLite cache."""
        try:
            memories = await self.memory.recall_recent(
                project=self.project,
                limit=50,
            )
            if not memories:
                return

            rows = [
                {
                    "id": m.id,
                    "memory_type": m.memory_type,
                    "trigger": m.trigger,
                    "context": m.context,
                    "reasoning": m.reasoning,
                    "actions_taken": m.actions_taken,
                    "outcome": m.outcome,
                    "summary": m.summary,
                    "tokens_used": m.tokens_used,
                    "model": m.model,
                    "created_at": str(m.created_at) if m.created_at else "",
                }
                for m in memories
            ]
            count = await self.local.warm_from_pg(rows)
            if count:
                logger.debug(
                    "SyncWorker: sync-down cached %d memories for %s",
                    count,
                    self.project,
                )
        except Exception:
            logger.warning("SyncWorker: sync-down failed (non-fatal)", exc_info=True)

    async def _prune(self) -> None:
        """Prune stale PG memories and local SQLite housekeeping."""
        # PG prune — fire-and-forget
        try:
            deleted = await self.memory.prune_stale_memories()
            if deleted:
                logger.info(
                    "SyncWorker: pruned %d stale PG memories for %s",
                    deleted,
                    self.project,
                )
        except Exception:
            logger.warning("SyncWorker: PG prune failed (non-fatal)", exc_info=True)

        # SQLite prune — fire-and-forget
        try:
            counts = await self.local.prune()
            total = sum(counts.values())
            if total:
                logger.info(
                    "SyncWorker: pruned %d local SQLite rows for %s (%s)",
                    total,
                    self.project,
                    counts,
                )
        except Exception:
            logger.warning("SyncWorker: SQLite prune failed (non-fatal)", exc_info=True)

    async def _warm_if_empty(self) -> None:
        """On first boot, populate local SQLite from PG."""
        stats = await self.local.stats()
        if stats["total_memories"] > 0:
            return
        logger.info(
            "SyncWorker: empty local store, warming from PG for %s",
            self.project,
        )
        await self._sync_down()
