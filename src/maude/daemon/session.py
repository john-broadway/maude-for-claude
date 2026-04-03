# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Session context tools for the control plane
#          Claude (Anthropic) <noreply@anthropic.com>
"""Session context tools for the control plane.

Provides lean session loading and saving — replaces the old
session-load.py and session-save.py hooks with sidecar-based
tools that persist to 3-tier memory.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db import format_json as _format
from maude.memory.audit import AuditLogger

PROJECT = "my-service"


def register_session_tools(
    mcp: Any,
    audit: AuditLogger,
    project: str,
) -> None:
    """Register session context tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def jw_session_context() -> str:
        """Load lean session briefing for Claude Code startup.

        Queries PostgreSQL for recent sessions, active incidents,
        and last decisions. Returns ~300 tokens of context.

        Returns:
            JSON briefing with recent sessions, incidents, and decisions.
        """
        result: dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            "sessions": [],
            "incidents": [],
            "decisions": [],
        }

        try:
            import asyncpg

            from maude.daemon.common import pg_pool_kwargs

            kw = pg_pool_kwargs(database="agent", min_size=1, max_size=1)
            connect_kw = {k: v for k, v in kw.items() if k not in ("min_size", "max_size")}
            conn = await asyncpg.connect(**connect_kw)
            try:
                # Last 3 session summaries
                sessions = await conn.fetch(
                    "SELECT summary, created_at FROM agent_memory "
                    "WHERE project = $1 AND memory_type = 'session' "
                    "ORDER BY id DESC LIMIT 3",
                    project,
                )
                result["sessions"] = [
                    {
                        "time": r["created_at"].strftime("%Y-%m-%d %H:%M"),
                        "summary": (r["summary"] or "")[:100],
                    }
                    for r in sessions
                ]

                # Active incidents (24h)
                incidents = await conn.fetch(
                    "SELECT project, summary FROM agent_memory "
                    "WHERE memory_type = 'incident' "
                    "AND created_at > now() - interval '24 hours' "
                    "ORDER BY id DESC LIMIT 3",
                )
                result["incidents"] = [
                    {"project": r["project"], "summary": (r["summary"] or "")[:80]}
                    for r in incidents
                ]

                # Last decision (48h)
                decision = await conn.fetchrow(
                    "SELECT project, summary FROM agent_memory "
                    "WHERE memory_type = 'decision' "
                    "AND created_at > now() - interval '48 hours' "
                    "ORDER BY id DESC LIMIT 1",
                )
                if decision and decision["summary"]:
                    result["decisions"] = [
                        {"project": decision["project"], "summary": decision["summary"][:80]}
                    ]

            finally:
                await conn.close()
        except Exception as e:
            result["pg_error"] = str(e)[:100]

        # Redis last session
        try:
            import redis as redis_lib

            from maude.daemon.common import resolve_redis_host

            r = redis_lib.Redis(
                host=resolve_redis_host(),
                port=6379,
                decode_responses=True,
                socket_connect_timeout=2,
            )
            last = r.get(f"maude:{project}:last_session")
            if last:
                result["last_session"] = json.loads(last)
            r.close()
        except Exception:
            pass

        return _format(result)

    @mcp.tool()
    @audit_logged(audit)
    async def jw_session_save(
        summary: str,
        tool_count: int = 0,
        session_id: str = "",
    ) -> str:
        """Persist session summary to 3-tier memory.

        Saves to PostgreSQL (Tier 2), Qdrant (Tier 3), and Redis.
        Replaces the old session-save.py hook.

        Args:
            summary: Session summary text (1-2 sentences).
            tool_count: Number of tool calls in the session.
            session_id: Claude Code session ID.

        Returns:
            JSON with save status per tier.
        """
        result: dict[str, Any] = {"saved": {}}
        now = datetime.now(timezone.utc)

        # Tier 2: PostgreSQL
        pg_id = None
        try:
            import asyncpg

            from maude.daemon.common import pg_pool_kwargs

            kw = pg_pool_kwargs(database="agent", min_size=1, max_size=1)
            connect_kw = {k: v for k, v in kw.items() if k not in ("min_size", "max_size")}
            conn = await asyncpg.connect(**connect_kw)
            try:
                context = json.dumps(
                    {
                        "session_id": session_id,
                        "tools_used": tool_count,
                    }
                )
                pg_id = await conn.fetchval(
                    "INSERT INTO agent_memory "
                    "(project, memory_type, trigger, context, summary, outcome) "
                    "VALUES ($1, $2, $3, $4::jsonb, $5, $6) "
                    "RETURNING id",
                    project,
                    "session",
                    "session_end",
                    context,
                    summary,
                    "completed",
                )
                result["saved"]["postgresql"] = {"id": pg_id}
            finally:
                await conn.close()
        except Exception as e:
            result["saved"]["postgresql"] = {"error": str(e)[:100]}

        # Redis
        try:
            import redis as redis_lib

            from maude.daemon.common import resolve_redis_host

            r = redis_lib.Redis(
                host=resolve_redis_host(),
                port=6379,
                decode_responses=True,
                socket_connect_timeout=2,
            )
            r.set(
                f"maude:{project}:last_session",
                json.dumps(
                    {
                        "timestamp": now.strftime("%Y-%m-%d %H:%M UTC"),
                        "summary": summary[:200],
                        "tool_count": tool_count,
                        "session_id": session_id,
                    }
                ),
                ex=7 * 86400,
            )
            result["saved"]["redis"] = True
            r.close()
        except Exception as e:
            result["saved"]["redis"] = {"error": str(e)[:100]}

        # Tier 3: Qdrant (via embedding)
        if pg_id:
            try:
                import uuid

                import httpx

                embedder_urls = [
                    "http://localhost:8001/v1/embeddings",
                    "http://localhost:8001/v1/embeddings",
                ]
                embedding = None
                async with httpx.AsyncClient(timeout=5.0) as client:
                    for url in embedder_urls:
                        try:
                            resp = await client.post(
                                url,
                                json={
                                    "model": "BAAI/bge-large-en-v1.5",
                                    "input": summary[:2000],
                                },
                            )
                            if resp.status_code == 200:
                                vec = resp.json()["data"][0]["embedding"]
                                if len(vec) == 1024:
                                    embedding = vec
                                    break
                        except Exception:
                            continue

                if embedding:
                    point_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"maude.memory.{pg_id}"))
                    point_data = {
                        "id": point_id,
                        "vector": embedding,
                        "payload": {
                            "project": project,
                            "memory_type": "session",
                            "pg_id": pg_id,
                            "summary": summary[:500],
                            "created_at": now.isoformat(),
                        },
                    }
                    qdrant_url = "http://localhost:6333"
                    async with httpx.AsyncClient(timeout=5.0) as client:
                        resp = await client.put(
                            f"{qdrant_url}/collections/room_memory_{project}/points",
                            json={"points": [point_data]},
                        )
                        result["saved"]["qdrant"] = resp.status_code in (200, 201)
                        try:
                            await client.put(
                                f"{qdrant_url}/collections/vault/points",
                                json={"points": [point_data]},
                            )
                        except Exception:
                            pass
            except Exception as e:
                result["saved"]["qdrant"] = {"error": str(e)[:100]}

        return _format(result)
