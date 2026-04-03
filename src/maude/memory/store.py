"""Memory store for Room Agents — SQLite + PostgreSQL + Qdrant.

Tier 1.5 (SQLite): Local sovereign memory — survives PG/Qdrant outages.
Tier 2 (PostgreSQL): Shared structured memory — incidents, patterns, decisions.
Tier 3 (Qdrant): Semantic memory — vector embeddings for similarity search.

Write path:  SQLite first (always) → PG (if available) → queue Qdrant
Read path:   PG first (authoritative) → SQLite fallback (if PG is down)
Sync:        SyncWorker promotes local records to PG/Qdrant in background.

Usage:
    store = MemoryStore(project="grafana", db_host="192.0.2.30")
    await store.store_memory(...)
    recent = await store.recall_recent("grafana", "incident", limit=5)
    similar = await store.recall_similar("grafana", "datasource connection refused", limit=3)
"""

import asyncio
import hashlib
import json
import logging
import os
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

import asyncpg
from qdrant_client import AsyncQdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

from maude.daemon.common import resolve_infra_hosts
from maude.db import PoolRegistry

logger = logging.getLogger(__name__)

_DEFAULT_QDRANT_PORT = 6333

_qdrant_host_cache: str | None = None


def _get_qdrant_host() -> str:
    """Lazily resolve the Qdrant host, caching after first call."""
    global _qdrant_host_cache
    host = _qdrant_host_cache
    if host is None:
        host = resolve_infra_hosts()["qdrant"]
        _qdrant_host_cache = host
    return host


QDRANT_PORT = _DEFAULT_QDRANT_PORT
QDRANT_COLLECTION_PREFIX = "room_memory"
VAULT_COLLECTION = "vault"

# Embedding config — defaults match vLLM serving BAAI/bge-large-en-v1.5 (1024-dim).
# Override via MAUDE_EMBEDDING_MODEL / MAUDE_EMBEDDING_DIM env vars.
EMBEDDING_DIM = int(os.environ.get("MAUDE_EMBEDDING_DIM", "1024"))
EMBEDDING_MODEL = os.environ.get("MAUDE_EMBEDDING_MODEL", "BAAI/bge-large-en-v1.5")

# Progressive backoff tiers for Qdrant collection retry (seconds)
_COLLECTION_RETRY_TIERS = [30, 120, 300, 600]

# Embedding cache size — override via MAUDE_EMBED_CACHE_SIZE env var
_EMBED_CACHE_SIZE = int(os.environ.get("MAUDE_EMBED_CACHE_SIZE", "256"))


@dataclass
class Memory:
    """A single memory record."""

    id: int | None = None
    project: str = ""
    memory_type: str = ""
    trigger: str = ""
    context: dict[str, Any] = field(default_factory=dict)
    reasoning: str = ""
    actions_taken: list[dict[str, Any]] = field(default_factory=list)
    outcome: str = ""
    summary: str = ""
    tokens_used: int = 0
    model: str = ""
    created_at: datetime | None = None
    score: float = 0.0  # similarity score from Qdrant


class MemoryStore:
    """PostgreSQL + Qdrant memory interface for Room Agents.

    Args:
        project: Project identifier (e.g., "grafana").
        db_host: PostgreSQL host. Defaults to LXC 201.
        database: PostgreSQL database name. Defaults to "agent".
    """

    # Atomic idempotent INSERT — single statement, no race condition (#1).
    # Uses a CTE: checks for existing row, only inserts if none found,
    # returns whichever ID applies. Parameters: $1=project, $2=memory_type,
    # $3=trigger, $4=context, $5=reasoning, $6=actions_taken, $7=outcome,
    # $8=summary, $9=tokens_used, $10=model, $11=root_cause, $12=conversation.
    #
    # For full database-level guarantee, add:
    #   CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_memory_idempotent
    #   ON agent_memory (project, memory_type, md5(summary));
    INSERT_SQL = """
        WITH existing AS (
            SELECT id FROM agent_memory
            WHERE project = $1 AND memory_type = $2 AND summary = $8
            LIMIT 1
        ), inserted AS (
            INSERT INTO agent_memory
                (project, memory_type, trigger, context, reasoning,
                 actions_taken, outcome, summary, tokens_used, model,
                 root_cause, conversation)
            SELECT $1, $2, $3, $4::jsonb, $5, $6::jsonb, $7, $8, $9, $10,
                   $11, $12::jsonb
            WHERE NOT EXISTS (SELECT 1 FROM existing)
            RETURNING id
        )
        SELECT COALESCE(
            (SELECT id FROM inserted),
            (SELECT id FROM existing)
        )
    """

    RECALL_SQL = """
        SELECT id, project, memory_type, trigger, context, reasoning,
               actions_taken, outcome, summary, tokens_used, model, created_at
        FROM agent_memory
        WHERE project = $1 AND memory_type = $2
        ORDER BY created_at DESC
        LIMIT $3
    """

    RECALL_ALL_SQL = """
        SELECT id, project, memory_type, trigger, context, reasoning,
               actions_taken, outcome, summary, tokens_used, model, created_at
        FROM agent_memory
        WHERE project = $1
        ORDER BY created_at DESC
        LIMIT $2
    """

    RECALL_BY_ID_SQL = """
        SELECT id, project, memory_type, trigger, context, reasoning,
               actions_taken, outcome, summary, tokens_used, model, created_at
        FROM agent_memory
        WHERE id = $1 AND project = $2
    """

    def __init__(
        self,
        project: str,
        db_host: str = "",
        database: str = "agent",
    ) -> None:
        self.project = project
        self.collection = f"{QDRANT_COLLECTION_PREFIX}_{project}"
        self.db_host = db_host or resolve_infra_hosts()["db"]
        self.database = database
        self._db = PoolRegistry.get(database=database, db_host=self.db_host)
        self._qdrant: AsyncQdrantClient | None = None
        self._vllm: Any = None  # VLLMClient, lazy-init to avoid circular import
        self._collection_ready = False
        self._collection_failed_at: float = 0.0
        self._collection_retry_count: int = 0
        # Embedding cache — LRU keyed on text hash
        self._embed_cache: OrderedDict[str, list[float]] = OrderedDict()
        self._embed_cache_size: int = _EMBED_CACHE_SIZE
        # Tier 1.5 — local SQLite (lazy-initialized)
        self._local: Any = None  # LocalStore, set via set_local_store()

    # Shared instances keyed by project — deduplicates _get_store() pattern
    _instances: dict[str, "MemoryStore"] = {}

    @classmethod
    def get_or_create(cls, project: str) -> "MemoryStore":
        """Get or create a shared MemoryStore for a project."""
        if project not in cls._instances:
            cls._instances[project] = cls(project=project)
        return cls._instances[project]

    def _get_vllm(self) -> Any:
        """Lazy-init VLLMClient to avoid circular import at module load."""
        if self._vllm is None:
            from maude.llm.vllm import VLLMClient

            self._vllm = VLLMClient()
        return self._vllm

    def set_local_store(self, local_store: Any) -> None:
        """Attach a LocalStore for SQLite-first writes and fallback reads."""
        self._local = local_store

    async def _ensure_pool(self):
        """Lazy-init PostgreSQL connection pool."""
        return await self._db.get()

    def _ensure_qdrant(self) -> AsyncQdrantClient:
        if self._qdrant is None:
            self._qdrant = AsyncQdrantClient(host=_get_qdrant_host(), port=QDRANT_PORT, timeout=30)
        return self._qdrant

    async def _ensure_collection(self) -> bool:
        """Create the per-project Qdrant collection if it doesn't exist.

        After a failure, waits with progressive backoff (30s, 120s, 300s,
        cap 600s) before retrying so a brief Qdrant outage doesn't
        permanently disable semantic search.
        """
        if self._collection_ready:
            return True
        # Respect progressive cooldown after a previous failure
        if self._collection_failed_at:
            tier_idx = min(self._collection_retry_count, len(_COLLECTION_RETRY_TIERS) - 1)
            cooldown = _COLLECTION_RETRY_TIERS[tier_idx]
            elapsed = time.monotonic() - self._collection_failed_at
            if elapsed < cooldown:
                return False
            # Cooldown expired — allow retry
            self._collection_failed_at = 0.0
        try:
            client = self._ensure_qdrant()
            exists = await client.collection_exists(self.collection)
            if not exists:
                await client.create_collection(
                    collection_name=self.collection,
                    vectors_config=VectorParams(
                        size=EMBEDDING_DIM,
                        distance=Distance.COSINE,
                    ),
                    on_disk_payload=True,
                )
                logger.info("MemoryStore: Created Qdrant collection %s", self.collection)
            self._collection_ready = True
            self._collection_retry_count = 0
            return True
        except Exception:
            logger.warning("MemoryStore: Failed to ensure Qdrant collection", exc_info=True)
            self._collection_failed_at = time.monotonic()
            self._collection_retry_count += 1
            return False

    async def store_memory(
        self,
        project: str,
        memory_type: str,
        summary: str,
        context: dict[str, Any] | None = None,
        trigger: str = "",
        reasoning: str = "",
        actions_taken: list[dict[str, Any]] | None = None,
        outcome: str = "",
        tokens_used: int = 0,
        model: str = "",
        root_cause: str = "",
        conversation: list[dict[str, Any]] | None = None,
    ) -> int | None:
        """Store a memory. Writes SQLite first (if available), then PostgreSQL.

        SQLite write is the sovereign floor — always succeeds locally.
        PG write promotes to shared memory. If PG fails, SyncWorker
        will retry from the local sync_queue.

        Returns the PG row ID, or None if PG is unavailable.
        """
        # Tier 1.5: Write locally first (always succeeds)
        # enqueue_sync=False because PG is handled inline below.
        # Qdrant (tier 4) is enqueued explicitly after PG succeeds.
        local_id: int | None = None
        if self._local:
            try:
                local_id = await self._local.store(
                    memory_type=memory_type,
                    summary=summary,
                    trigger=trigger,
                    context=context,
                    reasoning=reasoning,
                    actions_taken=actions_taken,
                    outcome=outcome,
                    tokens_used=tokens_used,
                    model=model,
                    root_cause=root_cause,
                    enqueue_sync=False,
                )
            except Exception:
                logger.warning("MemoryStore: LocalStore write failed (non-fatal)")

        # Tier 2: PostgreSQL
        pool = await self._ensure_pool()
        if pool is None:
            logger.warning("MemoryStore: PG unavailable — memory buffered in SQLite")
            return None

        try:
            # Atomic idempotent INSERT — CTE deduplicates in a single
            # statement, no race condition (#1).
            row_id = await pool.fetchval(
                self.INSERT_SQL,
                project,
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
                json.dumps(conversation, default=str) if conversation else None,
            )
            if row_id is not None:
                logger.info(
                    "MemoryStore: Stored %s memory #%d for %s",
                    memory_type,
                    row_id,
                    project,
                )

            # Enqueue tier 4 (Qdrant) sync now that we have a PG ID.
            if local_id and self._local:
                try:
                    await self._local.mark_synced(local_id, 3, pg_id=row_id)
                    await self._local.enqueue_sync(local_id, 4)
                except Exception:
                    logger.warning(
                        "MemoryStore: Qdrant sync enqueue failed for memory %d",
                        local_id,
                        exc_info=True,
                    )

            return row_id
        except Exception:
            logger.warning("MemoryStore: Failed to store memory", exc_info=True)
            return None

    async def recall_recent(
        self,
        project: str,
        memory_type: str | None = None,
        limit: int = 10,
        exclude_types: list[str] | None = None,
    ) -> list[Memory]:
        """Recall recent memories. PG first, SQLite fallback.

        Args:
            project: Project to recall from.
            memory_type: Optional filter to a specific type.
            limit: Max results.
            exclude_types: Memory types to exclude from results (e.g.,
                ``["check"]`` to skip routine health check noise).
        """
        pool = await self._ensure_pool()
        if pool is not None:
            try:
                coro = (
                    pool.fetch(self.RECALL_SQL, project, memory_type, limit)
                    if memory_type
                    else pool.fetch(self.RECALL_ALL_SQL, project, limit)
                )
                rows = await asyncio.wait_for(coro, timeout=10.0)
                memories = [_row_to_memory(row) for row in rows]
                if exclude_types:
                    memories = [m for m in memories if m.memory_type not in exclude_types]
                return memories
            except (asyncio.TimeoutError, Exception) as exc:
                label = "timed out" if isinstance(exc, asyncio.TimeoutError) else "failed"
                logger.warning("MemoryStore: PG recall %s, trying SQLite", label)

        # Fallback to local SQLite
        if self._local:
            try:
                local_rows = await self._local.recall_recent(
                    memory_type=memory_type,
                    limit=limit,
                )
                memories = [_local_row_to_memory(r, project) for r in local_rows]
                if exclude_types:
                    memories = [m for m in memories if m.memory_type not in exclude_types]
                return memories
            except Exception:
                logger.warning("MemoryStore: SQLite fallback also failed")
        return []

    async def recall_by_id(self, memory_id: int, project: str) -> Memory | None:
        """Recall a single memory by ID. PG first, SQLite fallback."""
        pool = await self._ensure_pool()
        if pool is not None:
            try:
                row = await pool.fetchrow(self.RECALL_BY_ID_SQL, memory_id, project)
                if row is not None:
                    return _row_to_memory(row)
            except Exception:
                logger.warning("MemoryStore: PG recall_by_id failed, trying SQLite")

        # Fallback to local SQLite (use negative ID convention for local-only)
        if self._local:
            try:
                local_row = await self._local.recall_by_id(abs(memory_id))
                if local_row:
                    return _local_row_to_memory(local_row, project)
            except Exception:
                logger.warning("MemoryStore: SQLite fallback also failed")
        return None

    async def recall_similar(
        self,
        project: str,
        query_text: str,
        limit: int = 5,
        min_score: float = 0.0,
    ) -> list[Memory] | None:
        """Recall semantically similar memories from Qdrant.

        Uses BGE-large embeddings via vLLM for similarity search.

        Args:
            project: Project to search within.
            query_text: Text to find similar memories for.
            limit: Max results to return.
            min_score: Minimum similarity score (0.0-1.0). Results below
                this threshold are filtered out. Default 0.0 (no filtering).

        Returns:
            List of memories on success, empty list if no matches,
            None if Qdrant is unavailable (allows callers to distinguish).
        """
        try:
            if not await self._ensure_collection():
                return None

            embedding = await self._embed(query_text)
            if not embedding:
                return None

            client = self._ensure_qdrant()
            result = await asyncio.wait_for(
                client.query_points(
                    collection_name=self.collection,
                    query=embedding,
                    limit=limit,
                ),
                timeout=10.0,
            )

            memories = []
            for point in result.points:
                # Score filter — skip low-relevance results
                if min_score > 0 and point.score < min_score:
                    continue
                payload_data = point.payload or {}
                # Hydrate enrichment fields into reasoning for context display
                reasoning_parts: list[str] = []
                if payload_data.get("actions_summary"):
                    reasoning_parts.append(f"Actions: {payload_data['actions_summary']}")
                if payload_data.get("root_cause"):
                    reasoning_parts.append(f"Root cause: {payload_data['root_cause']}")
                memories.append(
                    Memory(
                        id=payload_data.get("pg_id"),
                        project=payload_data.get("project", ""),
                        memory_type=payload_data.get("memory_type", ""),
                        summary=payload_data.get("summary", ""),
                        outcome=payload_data.get("outcome", ""),
                        reasoning="; ".join(reasoning_parts),
                        created_at=payload_data.get("created_at"),
                        score=point.score,
                    )
                )
            return memories
        except Exception:
            logger.warning("MemoryStore: Qdrant recall failed", exc_info=True)
            return None

    async def embed_and_store(
        self,
        memory_id: int,
        summary: str,
        memory_type: str,
        outcome: str,
        *,
        actions_summary: str = "",
        root_cause: str = "",
        tools_used: list[str] | None = None,
    ) -> bool:
        """Embed a memory summary and upsert to Qdrant.

        Checks MemoryTypePolicy.embed before proceeding — types like
        'check' and 'visit' skip embedding to reduce Qdrant noise.

        Called after storing to PostgreSQL to enable semantic recall.
        Optional enrichment fields are stored in the Qdrant payload
        for richer context during future recall.
        """
        from maude.memory.types import should_embed

        if not should_embed(memory_type, outcome):
            logger.debug(
                "MemoryStore: skipping embed for %s/%s (policy)",
                memory_type,
                outcome,
            )
            return True  # Not an error — policy says skip

        try:
            if not await self._ensure_collection():
                return False

            embedding = await self._embed(summary)
            if not embedding:
                return False

            client = self._ensure_qdrant()
            point_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"maude.memory.{memory_id}"))
            point_payload: dict[str, Any] = {
                "pg_id": memory_id,
                "project": self.project,
                "memory_type": memory_type,
                "summary": summary,
                "outcome": outcome,
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
            if actions_summary:
                point_payload["actions_summary"] = actions_summary
            if root_cause:
                point_payload["root_cause"] = root_cause
            if tools_used:
                point_payload["tools_used"] = tools_used

            await client.upsert(
                collection_name=self.collection,
                points=[PointStruct(id=point_id, vector=embedding, payload=point_payload)],
            )
            # Also upsert to vault (unified cross-room collection)
            try:
                await client.upsert(
                    collection_name=VAULT_COLLECTION,
                    points=[PointStruct(id=point_id, vector=embedding, payload=point_payload)],
                )
            except Exception:
                logger.debug("MemoryStore: vault upsert failed (non-fatal)")
            logger.info("MemoryStore: Embedded memory #%d in Qdrant", memory_id)
            return True
        except Exception:
            logger.warning("MemoryStore: Failed to embed in Qdrant", exc_info=True)
            return False

    # Policy-driven prune: deletes memories whose type has a finite retention
    # and whose age exceeds that retention. Types with retention_days=None
    # (pattern, remediation, decision) are never pruned.
    PRUNE_BY_TYPE_SQL = """
        DELETE FROM agent_memory
        WHERE id IN (
            SELECT id FROM agent_memory
            WHERE project = $1
              AND memory_type = $2
              AND created_at < now() - make_interval(days => $3)
            LIMIT 10000
        )
    """

    # Legacy SQL kept for the special check/no_action case (outcome filter)
    PRUNE_CHECK_SQL = """
        DELETE FROM agent_memory
        WHERE id IN (
            SELECT id FROM agent_memory
            WHERE project = $1
              AND memory_type = 'check'
              AND outcome = 'no_action'
              AND created_at < now() - make_interval(days => $2)
            LIMIT 10000
        )
    """

    BACKFILL_SQL = """
        SELECT id, summary, memory_type, outcome
        FROM agent_memory
        WHERE project = $1
          AND created_at > now() - interval '24 hours'
        ORDER BY created_at DESC
        LIMIT $2
    """

    async def prune_stale_memories(
        self,
        check_days: int = 14,
        incident_days: int = 180,
    ) -> int:
        """Delete stale memories based on MemoryTypePolicy retention rules.

        Iterates all known memory types and prunes those whose policy
        specifies a finite ``retention_days``. Types with
        ``retention_days=None`` (pattern, remediation, decision) are
        never pruned.

        The ``check_days`` and ``incident_days`` params are kept for
        backward compatibility but are no longer used — retention is
        driven by the policy registry in ``memory.types``.

        Returns count of deleted rows.
        """
        from maude.memory.types import MemoryType, get_policy

        pool = await self._ensure_pool()
        if pool is None:
            return 0

        deleted = 0

        # Special case: check/no_action uses outcome filter
        try:
            check_policy = get_policy("check")
            days = check_policy.retention_days or check_days
            result = await pool.execute(self.PRUNE_CHECK_SQL, self.project, days)
            deleted += _parse_delete_count(result)
        except Exception:
            logger.warning("MemoryStore: prune check memories failed", exc_info=True)

        # Policy-driven prune for all other types with finite retention
        for mt in MemoryType:
            if mt == MemoryType.CHECK:
                continue  # handled above with outcome filter
            policy = get_policy(mt.value)
            if policy.retention_days is None:
                continue  # permanent — never prune
            try:
                result = await pool.execute(
                    self.PRUNE_BY_TYPE_SQL,
                    self.project,
                    mt.value,
                    policy.retention_days,
                )
                deleted += _parse_delete_count(result)
            except Exception:
                logger.warning(
                    "MemoryStore: prune %s memories failed",
                    mt.value,
                    exc_info=True,
                )

        if deleted:
            logger.info("MemoryStore: pruned %d stale memories for %s", deleted, self.project)
        return deleted

    async def backfill_embeddings(self, limit: int = 50) -> int:
        """Re-embed recent memories that may have been missed during an outage.

        Queries PostgreSQL for recent memories and upserts embeddings into
        Qdrant using deterministic point IDs (based on pg_id) so the
        operation is idempotent.

        Returns the number of memories successfully embedded.
        """
        pool = await self._ensure_pool()
        if pool is None:
            return 0

        if not await self._ensure_collection():
            return 0

        try:
            rows = await pool.fetch(self.BACKFILL_SQL, self.project, limit)
        except Exception:
            logger.warning("MemoryStore: backfill query failed", exc_info=True)
            return 0

        client = self._ensure_qdrant()
        embedded = 0

        # Batch embed all summaries at once
        summaries = [row["summary"] for row in rows]
        embeddings = await self._embed_batch(summaries)

        for row, embedding in zip(rows, embeddings):
            if not embedding:
                continue
            try:
                point_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"maude.memory.{row['id']}"))
                point_payload = {
                    "pg_id": row["id"],
                    "project": self.project,
                    "memory_type": row["memory_type"],
                    "summary": row["summary"],
                    "outcome": row["outcome"] or "",
                    "created_at": datetime.now(timezone.utc).isoformat(),
                }
                point = PointStruct(id=point_id, vector=embedding, payload=point_payload)
                await client.upsert(collection_name=self.collection, points=[point])
                try:
                    await client.upsert(collection_name=VAULT_COLLECTION, points=[point])
                except Exception:
                    pass  # vault write is non-fatal
                embedded += 1
            except Exception:
                logger.warning(
                    "MemoryStore: backfill failed for memory #%d",
                    row["id"],
                    exc_info=True,
                )
                continue

        if embedded:
            logger.info(
                "MemoryStore: backfill embedded %d/%d memories for %s",
                embedded,
                len(rows),
                self.project,
            )
        return embedded

    def _cache_key(self, text: str) -> str:
        """Compute cache key for embedding cache.

        Includes the model name so cached vectors from one model are never
        returned after a model change (#3).
        """
        combined = f"{EMBEDDING_MODEL}:{text}"
        return hashlib.md5(combined.encode()).hexdigest()

    async def _embed(self, text: str) -> list[float] | None:
        """Generate embedding via vLLM with LRU cache.

        Uses VLLMClient for multi-host failover.
        Falls back to None if all hosts are unavailable.
        """
        # Check cache first
        key = self._cache_key(text)
        if key in self._embed_cache:
            self._embed_cache.move_to_end(key)
            return list(self._embed_cache[key])

        try:
            response = await asyncio.wait_for(
                self._get_vllm().embed(model=EMBEDDING_MODEL, input=text),
                timeout=15.0,
            )
            embeddings = [e for e in (response.embeddings or []) if e is not None]
            if embeddings and len(embeddings[0]) == EMBEDDING_DIM:
                result = list(embeddings[0])
                # Store in cache, evict oldest if full
                self._embed_cache[key] = result
                if len(self._embed_cache) > self._embed_cache_size:
                    self._embed_cache.popitem(last=False)
                return result
            dim = len(embeddings[0]) if embeddings else 0
            logger.warning("MemoryStore: Unexpected embedding dim: %s", dim)
        except Exception:
            logger.warning("MemoryStore: Embedding failed", exc_info=True)

        return None

    async def _embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        """Embed multiple texts, using cache where possible.

        Collects uncached texts, embeds them in a single vLLM call,
        then returns results in order matching the input list.
        """
        results: list[list[float] | None] = [None] * len(texts)
        uncached_indices: list[int] = []
        uncached_texts: list[str] = []

        for i, text in enumerate(texts):
            key = self._cache_key(text)
            if key in self._embed_cache:
                self._embed_cache.move_to_end(key)
                results[i] = list(self._embed_cache[key])
            else:
                uncached_indices.append(i)
                uncached_texts.append(text)

        if not uncached_texts:
            return results

        try:
            response = await self._get_vllm().embed(model=EMBEDDING_MODEL, input=uncached_texts)
            raw_embeddings = [e for e in (response.embeddings or []) if e is not None]
            for j, embedding in enumerate(raw_embeddings):
                if j < len(uncached_indices) and len(embedding) == EMBEDDING_DIM:
                    vec = list(embedding)
                    idx = uncached_indices[j]
                    results[idx] = vec
                    # Cache the result
                    key = self._cache_key(uncached_texts[j])
                    self._embed_cache[key] = vec
                    if len(self._embed_cache) > self._embed_cache_size:
                        self._embed_cache.popitem(last=False)
        except Exception:
            logger.warning("MemoryStore: Batch embedding failed", exc_info=True)

        return results

    async def close(self) -> None:
        """Clean up connections."""
        await self._db.close()
        if self._qdrant:
            await self._qdrant.close()
            self._qdrant = None
        if self._vllm:
            await self._vllm.close()
        if self._local:
            await self._local.close()


def _row_to_memory(row: asyncpg.Record) -> Memory:
    """Convert a database row to a Memory object."""
    actions = row["actions_taken"]
    if isinstance(actions, str):
        actions = json.loads(actions)

    context = row["context"]
    if isinstance(context, str):
        context = json.loads(context)

    return Memory(
        id=row["id"],
        project=row["project"],
        memory_type=row["memory_type"],
        trigger=row["trigger"],
        context=context if isinstance(context, dict) else {},
        reasoning=row["reasoning"] or "",
        actions_taken=actions if isinstance(actions, list) else [],
        outcome=row["outcome"] or "",
        summary=row["summary"],
        tokens_used=row["tokens_used"] or 0,
        model=row["model"] or "",
        created_at=row["created_at"],
    )


def _local_row_to_memory(row: dict[str, Any], project: str) -> Memory:
    """Convert a SQLite dict row to a Memory object."""
    actions = row.get("actions_taken", "[]")
    if isinstance(actions, str):
        try:
            actions = json.loads(actions)
        except (json.JSONDecodeError, TypeError):
            actions = []

    context = row.get("context", "{}")
    if isinstance(context, str):
        try:
            context = json.loads(context)
        except (json.JSONDecodeError, TypeError):
            context = {}

    return Memory(
        id=row.get("pg_id") or -(row.get("id") or 0),  # negative = local-only
        project=project,
        memory_type=row.get("memory_type", ""),
        trigger=row.get("trigger", ""),
        context=context if isinstance(context, dict) else {},
        reasoning=row.get("reasoning", ""),
        actions_taken=actions if isinstance(actions, list) else [],
        outcome=row.get("outcome", ""),
        summary=row.get("summary", ""),
        tokens_used=row.get("tokens_used") or 0,
        model=row.get("model", ""),
        created_at=row.get("created_at"),
    )


def _parse_delete_count(result: str) -> int:
    """Extract row count from asyncpg DELETE command status string.

    asyncpg returns e.g. ``"DELETE 5"`` from ``pool.execute()``.
    """
    try:
        return int(result.split()[-1])
    except (ValueError, IndexError):
        return 0
