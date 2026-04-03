"""Structured inter-room relay with task state machine.

Replaces the fire-and-forget relay with delivery confirmation,
result tracking, and observability.

Task lifecycle::

    pending → accepted → running → completed
                                 → failed
              cancelled ←── (any non-terminal state)

Messages are stored in the ``relay_tasks`` table on the ``agent``
database. State changes publish PG NOTIFY on ``maude_events``.

Usage::

    relay = Relay(pool=pool)
    task_id = await relay.send("example-scada", "grafana", "Panel stale", "...")
    await relay.accept(task_id, "grafana")
    await relay.update(task_id, "grafana", "completed", result="Dashboard refreshed")
    tasks = await relay.tasks(room="grafana", status="pending")

Cross-site routing (CrossSiteRelay)::

    cross = CrossSiteRelay(local_relay=relay, sites=cfg, local_site="site-a")
    # Routes locally for bare room names, remotely for "site/room" notation:
    await cross.send("example-scada", "site-b/grafana", "Stale panel", "...")
    await cross.send("example-scada", "prometheus", "Alert", "...")  # local

Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
         Claude (Anthropic) <noreply@anthropic.com>
Version: 2.1.0
Updated: 2026-03-19
"""

import json
import logging
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Any

import asyncpg

from maude.db import LazyPool, PoolRegistry

logger = logging.getLogger(__name__)

# PG NOTIFY channel (shared with EventPublisher)
CHANNEL = "maude_events"

# Stale task timeouts (seconds)
PENDING_TIMEOUT_SECS = 30 * 60  # 30 minutes
RUNNING_TIMEOUT_SECS = 60 * 60  # 60 minutes


class TaskStatus(str, Enum):
    """Relay task statuses."""

    PENDING = "pending"
    ACCEPTED = "accepted"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


TERMINAL_STATUSES = {TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.CANCELLED}

VALID_TRANSITIONS: dict[TaskStatus, set[TaskStatus]] = {
    TaskStatus.PENDING: {
        TaskStatus.ACCEPTED,
        TaskStatus.RUNNING,
        TaskStatus.FAILED,
        TaskStatus.CANCELLED,
    },
    TaskStatus.ACCEPTED: {TaskStatus.RUNNING, TaskStatus.FAILED, TaskStatus.CANCELLED},
    TaskStatus.RUNNING: {TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.CANCELLED},
}


@dataclass
class RelayTask:
    """A relay task record."""

    id: int
    from_room: str
    to_room: str
    subject: str
    body: str
    status: TaskStatus
    result: str | None
    priority: int
    created_at: datetime
    updated_at: datetime
    accepted_at: datetime | None
    completed_at: datetime | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "from_room": self.from_room,
            "to_room": self.to_room,
            "subject": self.subject,
            "body": self.body,
            "status": self.status.value,
            "result": self.result,
            "priority": self.priority,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "accepted_at": self.accepted_at.isoformat() if self.accepted_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }


def _row_to_task(row: asyncpg.Record) -> RelayTask:
    """Convert an asyncpg Record to a RelayTask."""
    return RelayTask(
        id=row["id"],
        from_room=row["from_room"],
        to_room=row["to_room"],
        subject=row["subject"],
        body=row["body"],
        status=TaskStatus(row["status"]),
        result=row["result"],
        priority=row["priority"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        accepted_at=row["accepted_at"],
        completed_at=row["completed_at"],
    )


class Relay:
    """Structured inter-room relay with task state machine.

    Args:
        pool: An asyncpg connection pool. If *None*, one will be created
            lazily on first use from credentials.
    """

    def __init__(self, pool: asyncpg.Pool | None = None) -> None:
        if pool is not None:
            # Caller provided a pool — wrap in a standalone LazyPool (not shared)
            self._db = LazyPool(database="agent", suppress_errors=True)
            self._db._pool = pool
        else:
            self._db = PoolRegistry.get(database="agent", suppress_errors=True)
        self._owns_pool = pool is None

    async def _ensure_pool(self) -> asyncpg.Pool:
        pool = await self._db.get()
        if pool is None:
            raise ConnectionError("PostgreSQL agent database unavailable")
        return pool

    async def send(
        self,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int:
        """Create a relay task in ``pending`` status. Returns the task ID."""
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    """INSERT INTO relay_tasks
                       (from_room, to_room, subject, body, priority)
                       VALUES ($1, $2, $3, $4, $5)
                       RETURNING id""",
                    from_room,
                    to_room,
                    subject,
                    body,
                    priority,
                )
                if row is None:
                    raise RuntimeError("INSERT into relay_tasks returned no row")
                task_id = row["id"]
                logger.info(
                    "Relay: %s → %s [%s] (id=%d, priority=%d)",
                    from_room,
                    to_room,
                    subject,
                    task_id,
                    priority,
                )
                await self._notify(
                    conn,
                    "relay_task_created",
                    {
                        "task_id": task_id,
                        "from_room": from_room,
                        "to_room": to_room,
                        "subject": subject,
                    },
                )
                return task_id

    async def send_lenient(
        self,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int | None:
        """Like send() but returns None instead of raising on PG failure."""
        try:
            return await self.send(from_room, to_room, subject, body, priority)
        except Exception:
            return None

    async def accept(self, task_id: int, room: str) -> RelayTask:
        """Transition a task from ``pending`` to ``accepted``.

        Args:
            task_id: The relay task ID.
            room: The room accepting the task (must match to_room).

        Raises:
            ValueError: If transition is invalid or room doesn't match.
        """
        return await self._transition(
            task_id,
            room,
            TaskStatus.ACCEPTED,
            extra_sql="accepted_at = NOW(),",
        )

    async def update(
        self,
        task_id: int,
        room: str,
        status: str,
        result: str = "",
    ) -> RelayTask:
        """Transition a task to a new status.

        Args:
            task_id: The relay task ID.
            room: The room updating the task (must match to_room).
            status: Target status (running, completed, failed, cancelled).
            result: Result text (for completed/failed).

        Raises:
            ValueError: If transition is invalid.
        """
        target = TaskStatus(status)
        extra_sql = ""
        if target in TERMINAL_STATUSES:
            extra_sql = "completed_at = NOW(),"
        return await self._transition(
            task_id,
            room,
            target,
            result=result,
            extra_sql=extra_sql,
        )

    async def get(self, task_id: int) -> RelayTask | None:
        """Fetch a single task by ID."""
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM relay_tasks WHERE id = $1",
                task_id,
            )
            return _row_to_task(row) if row else None

    async def tasks(
        self,
        room: str = "",
        status: str = "",
        from_room: str = "",
        limit: int = 20,
        since_minutes: int = 0,
    ) -> list[RelayTask]:
        """Query relay tasks with optional filters.

        Args:
            room: Filter by to_room.
            status: Filter by status.
            from_room: Filter by from_room.
            limit: Maximum results.
            since_minutes: Only return tasks from the last N minutes.
        """
        pool = await self._ensure_pool()
        conditions = []
        params: list[Any] = []
        idx = 1

        if room:
            conditions.append(f"to_room = ${idx}")
            params.append(room)
            idx += 1
        if status:
            conditions.append(f"status = ${idx}")
            params.append(status)
            idx += 1
        if from_room:
            conditions.append(f"from_room = ${idx}")
            params.append(from_room)
            idx += 1
        if since_minutes > 0:
            conditions.append(f"created_at > NOW() - make_interval(mins => ${idx})")
            params.append(since_minutes)
            idx += 1

        where = "WHERE " + " AND ".join(conditions) if conditions else ""
        params.append(limit)

        async with pool.acquire() as conn:
            rows = await conn.fetch(
                f"SELECT * FROM relay_tasks {where} ORDER BY created_at DESC LIMIT ${idx}",
                *params,
            )
            return [_row_to_task(r) for r in rows]

    async def inbox(
        self,
        room: str,
        limit: int = 20,
        since_minutes: int = 60,
    ) -> list[dict[str, Any]]:
        """Retrieve recent tasks for *room* (backward-compatible format).

        Returns list of dicts matching the old Relay.inbox() shape.
        """
        result = await self.tasks(
            room=room,
            limit=limit,
            since_minutes=since_minutes,
        )
        return [
            {
                "id": t.id,
                "body": t.body,
                "from_room": t.from_room,
                "to_room": t.to_room,
                "subject": t.subject,
                "status": t.status.value,
                "ts": t.created_at.isoformat(),
            }
            for t in result
        ]

    async def sweep_stale(self) -> list[int]:
        """Mark stale tasks as failed.

        Tasks stuck ``pending`` > 30min, ``accepted`` > 60min, or
        ``running`` > 60min get marked ``failed`` with result ``timeout``.

        Returns:
            List of task IDs that were marked failed.
        """
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                """UPDATE relay_tasks
                   SET status = 'failed',
                       result = 'timeout',
                       updated_at = NOW(),
                       completed_at = NOW()
                   WHERE (
                       (status = 'pending' AND updated_at < NOW() - interval '30 minutes')
                       OR (status = 'accepted' AND updated_at < NOW() - interval '60 minutes')
                       OR (status = 'running' AND updated_at < NOW() - interval '60 minutes')
                   )
                   RETURNING id""",
            )
            ids = [r["id"] for r in rows]
            if ids:
                logger.info("Relay sweep: %d stale tasks marked failed: %s", len(ids), ids)
            return ids

    async def close(self) -> None:
        """Close the pool if we created it."""
        if self._owns_pool:
            await self._db.close()

    # ── Internal ─────────────────────────────────────────────────

    async def _transition(
        self,
        task_id: int,
        room: str,
        target: TaskStatus,
        *,
        result: str = "",
        extra_sql: str = "",
    ) -> RelayTask:
        """Execute a validated state transition."""
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            async with conn.transaction():
                # Fetch current state
                row = await conn.fetchrow(
                    "SELECT * FROM relay_tasks WHERE id = $1 FOR UPDATE",
                    task_id,
                )
                if not row:
                    raise ValueError(f"Task {task_id} not found")

                current = TaskStatus(row["status"])
                allowed = VALID_TRANSITIONS.get(current, set())
                if target not in allowed:
                    raise ValueError(
                        f"Invalid transition: {current.value} → {target.value} "
                        f"(allowed: {', '.join(s.value for s in allowed)})"
                    )

                # Cancelled can come from either sender or receiver;
                # all other transitions require the receiver (to_room).
                if target == TaskStatus.CANCELLED:
                    if row["to_room"] != room and row["from_room"] != room:
                        raise ValueError(
                            f"Room '{room}' cannot cancel task {task_id} (not sender or receiver)"
                        )
                elif row["to_room"] != room:
                    raise ValueError(
                        f"Room '{room}' cannot update task {task_id} (to_room='{row['to_room']}')"
                    )

                # Execute update
                result_clause = "result = $3," if result else ""
                sql = f"""UPDATE relay_tasks
                          SET status = $2,
                              {result_clause}
                              {extra_sql}
                              updated_at = NOW()
                          WHERE id = $1
                          RETURNING *"""

                params: list[Any] = [task_id, target.value]
                if result:
                    params.append(result)

                updated = await conn.fetchrow(sql, *params)
                if updated is None:
                    raise RuntimeError(f"UPDATE relay_tasks returned no row for task {task_id}")

                task = _row_to_task(updated)
                logger.info(
                    "Relay task %d: %s → %s (room=%s)",
                    task_id,
                    current.value,
                    target.value,
                    room,
                )
                await self._notify(
                    conn,
                    "relay_task_update",
                    {
                        "task_id": task_id,
                        "from_room": row["from_room"],
                        "to_room": row["to_room"],
                        "old_status": current.value,
                        "new_status": target.value,
                    },
                )
                return task

    async def _notify(
        self,
        conn: Any,
        event_type: str,
        data: dict[str, Any],
    ) -> None:
        """Publish a PG NOTIFY event (fire-and-forget)."""
        try:
            payload = json.dumps(
                {
                    "room": "coordinator",
                    "event": event_type,
                    "data": data,
                },
                default=str,
            )
            await conn.execute("SELECT pg_notify($1, $2)", CHANNEL, payload)
        except Exception:
            logger.debug("Relay NOTIFY failed (non-fatal)")


class CrossSiteRelay:
    """Routes relay tasks to the correct site using ``site/room`` addressing.

    Room addressing:

    - ``"room"`` — local site (delegates to the local Relay)
    - ``"site-b/room"`` — remote site (inserts into that site's relay_tasks)

    The sender writes directly into the remote site's ``relay_tasks`` table.
    The receiving Coordinator's existing relay machinery picks it up without
    any changes — cross-site is transparent to the receiver.

    Args:
        local_relay: Relay instance that handles local-site sends.
        sites: Dict of site_name -> {host, port, user, password, database}.
               Loaded from the ``federation`` section of secrets.yaml.
        local_site: Name of this Coordinator's site (e.g. ``"site-a"``).
                    Used to avoid a redundant remote connection for the local
                    site and to prefix ``from_room`` on cross-site sends.
    """

    def __init__(
        self,
        local_relay: Relay,
        sites: dict[str, dict[str, Any]],
        local_site: str = "",
    ) -> None:
        # Local import avoids a module-level circular reference
        from maude.coordination.cross_site_memory import SiteConnection

        self._local = local_relay
        self._local_site = local_site
        self._sites: dict[str, Any] = {
            name: SiteConnection(
                site=name,
                host=cfg["host"],
                port=int(cfg.get("port", 5432)),
                database=str(cfg.get("database", "agent")),
                user=str(cfg.get("user", "support")),
                password=str(cfg.get("password", "")),
            )
            for name, cfg in sites.items()
            if name != local_site
        }

    @staticmethod
    def _parse_room(to_room: str) -> tuple[str, str]:
        """Split ``site/room`` into ``(site, room)``.

        Returns ``("", to_room)`` for bare room names (local routing).
        """
        if "/" in to_room:
            site, room = to_room.split("/", 1)
            return site, room
        return "", to_room

    async def send(
        self,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int | None:
        """Send a relay task, routing to the correct site.

        Args:
            from_room: Sender room name (bare, without site prefix).
            to_room: Recipient. Use ``"site/room"`` for cross-site
                     (e.g. ``"site-b/grafana"``). Bare name routes locally.
            subject: Short task subject.
            body: Task body / instructions.
            priority: Task priority (higher = more urgent). Defaults to 0.

        Returns:
            Task ID on success, or None if the remote site was unreachable.
        """
        site, room = self._parse_room(to_room)
        if site and site != self._local_site and site in self._sites:
            return await self._send_remote(site, from_room, room, subject, body, priority)
        return await self._local.send_lenient(from_room, room, subject, body, priority)

    async def _send_remote(
        self,
        site: str,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int,
    ) -> int | None:
        """Insert a relay task into a remote site's ``relay_tasks`` table.

        ``from_room`` is prefixed with the local site name so the receiver
        can identify the origin (e.g. ``"site-a/example-scada"``).
        """
        conn = self._sites[site]
        pool = await conn.get_pool()
        if pool is None:
            logger.warning(
                "CrossSiteRelay: site %s unreachable, dropping relay to %s",
                site,
                to_room,
            )
            return None
        qualified_from = f"{self._local_site}/{from_room}" if self._local_site else from_room
        try:
            async with pool.acquire() as pg_conn:
                row = await pg_conn.fetchrow(
                    """INSERT INTO relay_tasks
                       (from_room, to_room, subject, body, priority)
                       VALUES ($1, $2, $3, $4, $5)
                       RETURNING id""",
                    qualified_from,
                    to_room,
                    subject,
                    body,
                    priority,
                )
                if row is None:
                    logger.warning("CrossSiteRelay: INSERT to site %s returned no row", site)
                    return None
                task_id: int = row["id"]
                logger.info(
                    "CrossSiteRelay: %s → %s/%s [%s] (id=%d)",
                    qualified_from,
                    site,
                    to_room,
                    subject,
                    task_id,
                )
                return task_id
        except Exception:
            logger.warning(
                "CrossSiteRelay: failed to relay to site %s/%s",
                site,
                to_room,
                exc_info=True,
            )
            return None

    async def close(self) -> None:
        """Close all remote site connection pools."""
        for conn in self._sites.values():
            await conn.close()
