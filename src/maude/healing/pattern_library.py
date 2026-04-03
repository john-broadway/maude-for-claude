# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""PatternLibrary — cross-room fix patterns backed by PostgreSQL + Qdrant.

Stores and retrieves shared resolution patterns that can be applied across
Rooms. PostgreSQL holds the structured data; Qdrant enables semantic search
by trigger signature so Rooms can find relevant fixes even when the exact
wording differs.

Usage:
    lib = PatternLibrary()
    await lib.contribute_pattern("monitoring", "datasource timeout", "restart my-service")
    matches = await lib.find_pattern("connection refused to postgres")
    await lib.close()
"""

import logging
import os
import time
import uuid
from dataclasses import dataclass, field

import asyncpg
from qdrant_client import AsyncQdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

from maude.daemon.common import resolve_infra_hosts
from maude.db import LazyPool
from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)

_DEFAULT_QDRANT_PORT = 6333

QDRANT_HOST = resolve_infra_hosts()["qdrant"]
QDRANT_PORT = _DEFAULT_QDRANT_PORT
QDRANT_COLLECTION = "shared_patterns"

EMBEDDING_DIM = int(os.environ.get("MAUDE_EMBEDDING_DIM", "1024"))
EMBEDDING_MODEL = os.environ.get("MAUDE_EMBEDDING_MODEL", "BAAI/bge-large-en-v1.5")

_COLLECTION_RETRY_COOLDOWN = 300  # 5 minutes
_SEMANTIC_DEDUP_THRESHOLD = 0.85  # Cosine similarity above this = same pattern


@dataclass
class SharedPattern:
    id: int | None = None
    source_room: str = ""
    pattern_type: str = "fix"
    trigger_signature: str = ""
    resolution: str = ""
    applicable_rooms: list[str] = field(default_factory=list)
    success_count: int = 1
    score: float = 0.0


class PatternLibrary:
    """PostgreSQL + Qdrant interface for cross-room fix patterns.

    Args:
        db_host: PostgreSQL host override. Empty string resolves from credentials.
    """

    FIND_BY_TRIGGER_SQL = """
        SELECT id, source_room, pattern_type, trigger_signature, resolution,
               applicable_rooms, success_count
        FROM shared_patterns
        WHERE trigger_signature = $1
        LIMIT 1
    """

    APPLICABLE_SQL = """
        SELECT id, source_room, pattern_type, trigger_signature, resolution,
               applicable_rooms, success_count
        FROM shared_patterns
        WHERE $1 = ANY(applicable_rooms) OR applicable_rooms = '{}'
        ORDER BY success_count DESC
        LIMIT $2
    """

    INSERT_SQL = """
        INSERT INTO shared_patterns
            (source_room, pattern_type, trigger_signature, resolution,
             applicable_rooms, success_count)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
    """

    INCREMENT_SQL = """
        UPDATE shared_patterns
        SET success_count = success_count + 1, last_applied = NOW()
        WHERE id = $1
    """

    def __init__(self, db_host: str = "") -> None:
        self._db_host = db_host
        self._db = LazyPool(
            database="agent",
            db_host=db_host,
            min_size=1,
            max_size=2,
        )
        self._qdrant: AsyncQdrantClient | None = None
        self._vllm = VLLMClient()
        self._collection_ready = False
        self._collection_failed_at: float = 0.0

    # ── Connection helpers ────────────────────────────────────────

    async def _ensure_pool(self):
        return await self._db.get()

    def _ensure_qdrant(self) -> AsyncQdrantClient:
        if self._qdrant is None:
            self._qdrant = AsyncQdrantClient(host=QDRANT_HOST, port=QDRANT_PORT, timeout=30)
        return self._qdrant

    async def _ensure_collection(self) -> bool:
        if self._collection_ready:
            return True
        if self._collection_failed_at:
            elapsed = time.monotonic() - self._collection_failed_at
            if elapsed < _COLLECTION_RETRY_COOLDOWN:
                return False
            self._collection_failed_at = 0.0
        try:
            client = self._ensure_qdrant()
            exists = await client.collection_exists(QDRANT_COLLECTION)
            if not exists:
                await client.create_collection(
                    collection_name=QDRANT_COLLECTION,
                    vectors_config=VectorParams(
                        size=EMBEDDING_DIM,
                        distance=Distance.COSINE,
                    ),
                    on_disk_payload=True,
                )
                logger.info("PatternLibrary: Created Qdrant collection %s", QDRANT_COLLECTION)
            self._collection_ready = True
            return True
        except Exception:
            logger.warning("PatternLibrary: Failed to ensure Qdrant collection", exc_info=True)
            self._collection_failed_at = time.monotonic()
            return False

    async def _embed(self, text: str) -> list[float] | None:
        try:
            response = await self._vllm.embed(model=EMBEDDING_MODEL, input=text)
            embeddings = response.embeddings or []
            if embeddings and len(embeddings[0]) == EMBEDDING_DIM:
                return list(embeddings[0])
            dim = len(embeddings[0]) if embeddings else 0
            logger.warning("PatternLibrary: Unexpected embedding dim: %s", dim)
        except Exception:
            logger.warning("PatternLibrary: Embedding failed", exc_info=True)
        return None

    # ── Public API ────────────────────────────────────────────────

    async def find_pattern(
        self,
        trigger: str,
        room: str = "",
    ) -> list[SharedPattern]:
        """Find patterns matching a trigger signature.

        Uses Qdrant semantic search first, then falls back to SQL exact match.
        If a room is provided, results applicable to that room are ranked higher.
        """
        patterns: list[SharedPattern] = []

        # Semantic search via Qdrant
        if await self._ensure_collection():
            embedding = await self._embed(trigger)
            if embedding:
                try:
                    client = self._ensure_qdrant()
                    result = await client.query_points(
                        collection_name=QDRANT_COLLECTION,
                        query=embedding,
                        limit=10,
                    )
                    for point in result.points:
                        payload = point.payload or {}
                        applicable = payload.get("applicable_rooms", [])
                        patterns.append(
                            SharedPattern(
                                id=payload.get("pg_id"),
                                source_room=payload.get("source_room", ""),
                                pattern_type=payload.get("pattern_type", "fix"),
                                trigger_signature=payload.get("trigger_signature", ""),
                                resolution=payload.get("resolution", ""),
                                applicable_rooms=applicable if isinstance(applicable, list) else [],
                                success_count=payload.get("success_count", 1),
                                score=point.score,
                            )
                        )
                except Exception:
                    logger.warning("PatternLibrary: Qdrant search failed", exc_info=True)

        # SQL fallback when Qdrant returns nothing
        if not patterns:
            pool = await self._ensure_pool()
            if pool:
                try:
                    row = await pool.fetchrow(self.FIND_BY_TRIGGER_SQL, trigger)
                    if row:
                        patterns.append(_row_to_pattern(row))
                except Exception:
                    logger.warning("PatternLibrary: SQL lookup failed", exc_info=True)

        # Boost patterns applicable to the requesting room
        if room and patterns:
            patterns.sort(
                key=lambda p: (room in p.applicable_rooms or not p.applicable_rooms, p.score),
                reverse=True,
            )

        return patterns

    async def contribute_pattern(
        self,
        source_room: str,
        trigger_signature: str,
        resolution: str,
        applicable_rooms: list[str] | None = None,
    ) -> int | None:
        """Store a new pattern or increment success_count if similar exists.

        Dedup strategy:
        1. Exact match on trigger_signature → increment
        2. Semantic similarity > 0.85 in Qdrant → increment closest match
        3. Otherwise → insert new pattern

        Returns the pattern ID on success, None on failure.
        """
        rooms = applicable_rooms or []
        embedding: list[float] | None = None
        pool = await self._ensure_pool()
        if pool is None:
            logger.warning("PatternLibrary: Cannot contribute — PostgreSQL unavailable")
            return None

        # 1. Exact match on trigger_signature
        try:
            existing = await pool.fetchrow(self.FIND_BY_TRIGGER_SQL, trigger_signature)
            if existing:
                pattern_id = existing["id"]
                await pool.execute(self.INCREMENT_SQL, pattern_id)
                logger.info(
                    "PatternLibrary: Exact match — incremented pattern #%d",
                    pattern_id,
                )
                return pattern_id
        except Exception:
            logger.warning("PatternLibrary: Duplicate check failed", exc_info=True)

        # 2. Semantic similarity check via Qdrant
        if await self._ensure_collection():
            embedding = await self._embed(trigger_signature)
            if embedding:
                try:
                    client = self._ensure_qdrant()
                    result = await client.query_points(
                        collection_name=QDRANT_COLLECTION,
                        query=embedding,
                        limit=1,
                    )
                    if result.points and result.points[0].score > _SEMANTIC_DEDUP_THRESHOLD:
                        match = result.points[0]
                        pg_id = (match.payload or {}).get("pg_id")
                        if pg_id:
                            await pool.execute(self.INCREMENT_SQL, pg_id)
                            logger.info(
                                "PatternLibrary: Semantic dedup (score=%.3f) — "
                                "incremented pattern #%d",
                                match.score,
                                pg_id,
                            )
                            return pg_id
                except Exception:
                    logger.warning("PatternLibrary: Semantic dedup check failed", exc_info=True)

        # 3. Insert new pattern
        try:
            pattern_id = await pool.fetchval(
                self.INSERT_SQL,
                source_room,
                "fix",
                trigger_signature,
                resolution,
                rooms,
                1,
            )
        except Exception:
            logger.warning("PatternLibrary: Failed to insert pattern", exc_info=True)
            return None

        # Embed in Qdrant (best-effort, reuse embedding from dedup check)
        if pattern_id and await self._ensure_collection():
            if not embedding:
                embedding = await self._embed(trigger_signature)
            if embedding:
                try:
                    client = self._ensure_qdrant()
                    point_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"maude.pattern.{pattern_id}"))
                    await client.upsert(
                        collection_name=QDRANT_COLLECTION,
                        points=[
                            PointStruct(
                                id=point_id,
                                vector=embedding,
                                payload={
                                    "pg_id": pattern_id,
                                    "source_room": source_room,
                                    "pattern_type": "fix",
                                    "trigger_signature": trigger_signature,
                                    "resolution": resolution,
                                    "applicable_rooms": rooms,
                                    "success_count": 1,
                                },
                            )
                        ],
                    )
                    logger.info("PatternLibrary: Embedded pattern #%d in Qdrant", pattern_id)
                except Exception:
                    logger.warning(
                        "PatternLibrary: Qdrant embed failed for pattern #%d",
                        pattern_id,
                        exc_info=True,
                    )

        return pattern_id

    async def applicable_patterns(self, room: str, limit: int = 5) -> list[SharedPattern]:
        """Patterns that apply to a specific room.

        Returns patterns where the room is in applicable_rooms, or where
        applicable_rooms is empty (universal patterns).
        """
        pool = await self._ensure_pool()
        if pool is None:
            return []
        try:
            rows = await pool.fetch(self.APPLICABLE_SQL, room, limit)
            return [_row_to_pattern(row) for row in rows]
        except Exception:
            logger.warning("PatternLibrary: applicable_patterns query failed", exc_info=True)
            return []

    async def close(self) -> None:
        await self._db.close()
        if self._qdrant:
            await self._qdrant.close()
            self._qdrant = None
        await self._vllm.close()


def _row_to_pattern(row: asyncpg.Record) -> SharedPattern:
    applicable = row["applicable_rooms"]
    if isinstance(applicable, str):
        applicable = [r.strip() for r in applicable.strip("{}").split(",") if r.strip()]
    elif not isinstance(applicable, list):
        applicable = []
    return SharedPattern(
        id=row["id"],
        source_room=row["source_room"],
        pattern_type=row["pattern_type"],
        trigger_signature=row["trigger_signature"],
        resolution=row["resolution"],
        applicable_rooms=applicable,
        success_count=row["success_count"],
    )
