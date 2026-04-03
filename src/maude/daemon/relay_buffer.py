# Maude Relay Buffer — Local SQLite outbox + background drain for relay resilience
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Created: 2026-03-15 MST
"""Local relay outbox with background drain to PostgreSQL / P2P HTTP.

When PG is unreachable, ``relay_send`` writes to a local SQLite outbox
instead of failing. The ``RelayOutboxWorker`` drains the outbox every
30 seconds — first trying PG, then falling back to direct HTTP POST
to the destination room's MCP endpoint (P2P).

Design mirrors the memory tier's SyncWorker pattern:
    - Write local FIRST (SQLite relay_outbox table)
    - Promote to PG via background worker
    - Fall back to P2P HTTP when PG is down
    - Max 10 attempts, then mark failed

Constitutional basis:
    - Art. II.3: P2P calls go through published MCP tool endpoints
    - Art. III.1: All relay operations audited
    - Art. IV.2: No capability loss — rooms keep communicating during PG outage
"""

import asyncio
import logging
import random
from contextlib import suppress
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

# Retry / drain configuration
MAX_ATTEMPTS = 10
DEFAULT_DRAIN_INTERVAL = 30  # seconds
DRAIN_BATCH_SIZE = 20
P2P_TIMEOUT = 10.0  # seconds


class RelayOutbox:
    """Local SQLite outbox for relay tasks when PG is unavailable.

    Uses the room's existing LocalStore SQLite database. The
    ``relay_outbox`` table is created by LocalStore's schema init.
    """

    def __init__(self, local_store: Any, project: str) -> None:
        self.local = local_store
        self.project = project

    async def enqueue(
        self,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int:
        """Buffer a relay task locally. Returns the outbox row ID."""
        await self.local.initialize()
        now = datetime.now(timezone.utc).isoformat()

        def _enqueue() -> int:
            conn = self.local._get_conn()
            cursor = conn.execute(
                "INSERT INTO relay_outbox (to_room, subject, body, priority, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (to_room, subject, body, priority, now),
            )
            local_id = cursor.lastrowid
            if local_id is None:
                raise RuntimeError("INSERT into relay_outbox returned no lastrowid")
            conn.commit()
            return local_id

        local_id = await asyncio.to_thread(_enqueue)
        logger.info(
            "Relay outbox: buffered %s → %s [%s] (local_id=%d)",
            self.project,
            to_room,
            subject,
            local_id,
        )
        return local_id

    async def pending(self, limit: int = DRAIN_BATCH_SIZE) -> list[dict[str, Any]]:
        """Get pending outbox entries that haven't exceeded max attempts."""
        await self.local.initialize()

        def _pending() -> list[dict[str, Any]]:
            conn = self.local._get_conn()
            rows = conn.execute(
                "SELECT * FROM relay_outbox "
                "WHERE status = 'pending' AND attempts < ? "
                "ORDER BY created_at ASC LIMIT ?",
                (MAX_ATTEMPTS, limit),
            ).fetchall()
            return [dict(r) for r in rows]

        return await asyncio.to_thread(_pending)

    async def mark_synced(self, outbox_id: int, pg_task_id: int | None = None) -> None:
        """Mark an outbox entry as successfully delivered."""
        now = datetime.now(timezone.utc).isoformat()

        def _mark() -> None:
            conn = self.local._get_conn()
            conn.execute(
                "UPDATE relay_outbox SET status = 'synced', pg_task_id = ?, "
                "last_attempt = ? WHERE id = ?",
                (pg_task_id, now, outbox_id),
            )
            conn.commit()

        await asyncio.to_thread(_mark)

    async def mark_failed(self, outbox_id: int) -> None:
        """Mark an outbox entry as permanently failed (max attempts)."""
        now = datetime.now(timezone.utc).isoformat()

        def _mark() -> None:
            conn = self.local._get_conn()
            conn.execute(
                "UPDATE relay_outbox SET status = 'failed', last_attempt = ? WHERE id = ?",
                (now, outbox_id),
            )
            conn.commit()

        await asyncio.to_thread(_mark)

    async def increment_attempt(self, outbox_id: int) -> None:
        """Increment attempt count; mark failed if max reached."""
        now = datetime.now(timezone.utc).isoformat()

        def _increment() -> None:
            conn = self.local._get_conn()
            conn.execute(
                "UPDATE relay_outbox "
                "SET attempts = attempts + 1, last_attempt = ?, "
                "    status = CASE WHEN attempts + 1 >= ? THEN 'failed' "
                "                  ELSE 'pending' END "
                "WHERE id = ?",
                (now, MAX_ATTEMPTS, outbox_id),
            )
            conn.commit()

        await asyncio.to_thread(_increment)

    async def stats(self) -> dict[str, Any]:
        """Return outbox statistics."""
        await self.local.initialize()

        def _stats() -> dict[str, Any]:
            conn = self.local._get_conn()
            pending = conn.execute(
                "SELECT COUNT(*) FROM relay_outbox WHERE status = 'pending'",
            ).fetchone()[0]
            synced = conn.execute(
                "SELECT COUNT(*) FROM relay_outbox WHERE status = 'synced'",
            ).fetchone()[0]
            failed = conn.execute(
                "SELECT COUNT(*) FROM relay_outbox WHERE status = 'failed'",
            ).fetchone()[0]
            return {"pending": pending, "synced": synced, "failed": failed}

        return await asyncio.to_thread(_stats)


class RelayOutboxWorker:
    """Background task that drains the local relay outbox to PG or P2P.

    Follows the SyncWorker pattern:
    - Runs as asyncio background task
    - Polls every ``interval`` seconds
    - For each pending entry: try PG → try P2P → increment attempt
    - Fire-and-forget: never crashes the room
    """

    def __init__(
        self,
        outbox: RelayOutbox,
        relay: Any,  # maude.coordination.relay.Relay
        project: str,
        dep_graph: Any | None = None,
        interval: int = DEFAULT_DRAIN_INTERVAL,
    ) -> None:
        self.outbox = outbox
        self.relay = relay
        self.project = project
        self._dep_graph = dep_graph
        self._interval = interval
        self._task: asyncio.Task[None] | None = None
        self._sweep_counter = 0

    async def start(self) -> None:
        """Start the drain worker as a background task."""
        self._task = asyncio.create_task(
            self._loop(),
            name=f"relay-outbox-{self.outbox.project}",
        )
        logger.info(
            "RelayOutboxWorker: started for %s (interval=%ds)",
            self.project,
            self._interval,
        )

    async def stop(self) -> None:
        """Stop the drain worker gracefully."""
        if self._task:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        logger.info("RelayOutboxWorker: stopped for %s", self.project)

    async def _loop(self) -> None:
        """Main drain loop — poll and drain pending outbox entries."""
        await asyncio.sleep(10 + random.uniform(0, 20))  # let services settle

        while True:
            try:
                await self._drain()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("RelayOutboxWorker: drain error (non-fatal)")

            await asyncio.sleep(self._interval)

    async def _drain(self) -> None:
        """Process pending outbox entries."""
        entries = await self.outbox.pending()
        if not entries:
            return

        synced = 0
        for entry in entries:
            outbox_id = entry["id"]
            to_room = entry["to_room"]
            subject = entry["subject"]
            body = entry["body"]
            priority = entry["priority"]

            # Try 1: PG via Relay.send_lenient()
            try:
                task_id = await self.relay.send_lenient(
                    self.project,
                    to_room,
                    subject,
                    body,
                    priority,
                )
                if task_id is not None:
                    await self.outbox.mark_synced(outbox_id, pg_task_id=task_id)
                    synced += 1
                    continue
            except Exception:
                pass  # PG still down — try P2P

            # Try 2: P2P HTTP direct to destination room
            try:
                if await self._try_p2p(to_room, subject, body):
                    await self.outbox.mark_synced(outbox_id)
                    synced += 1
                    continue
            except Exception:
                pass  # P2P also failed

            # Both failed — increment attempt counter
            await self.outbox.increment_attempt(outbox_id)

        if synced:
            logger.info(
                "RelayOutboxWorker: drained %d/%d entries for %s",
                synced,
                len(entries),
                self.project,
            )

        # Periodically sweep stale relay tasks from PG (~every 10th drain)
        self._sweep_counter += 1
        if self._sweep_counter >= 10:
            self._sweep_counter = 0
            try:
                await self.relay.sweep_stale()
            except Exception:
                pass  # fire-and-forget — PG may be down

    async def _try_p2p(self, to_room: str, subject: str, body: str) -> bool:
        """Direct HTTP POST to destination room's MCP endpoint.

        Uses DependencyGraph to resolve the room's IP and MCP port,
        then calls the room's ``relay_accept_incoming`` tool via
        JSON-RPC over HTTP (the standard MCP transport).
        """
        if not self._dep_graph:
            return False

        info = self._dep_graph.room_info(to_room)
        ip = info.get("ip", "")
        port = info.get("mcp_port") or 0
        if not ip or not port:
            return False

        try:
            import httpx
        except ImportError:
            return False

        url = f"http://{ip}:{port}/mcp"
        try:
            async with httpx.AsyncClient(timeout=P2P_TIMEOUT) as client:
                resp = await client.post(
                    url,
                    json={
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": {
                            "name": "relay_accept_incoming",
                            "arguments": {
                                "from_room": self.project,
                                "subject": subject,
                                "body": body,
                            },
                        },
                        "id": 1,
                    },
                )
                if resp.status_code == 200:
                    logger.info(
                        "RelayOutboxWorker: P2P delivery %s → %s [%s]",
                        self.project,
                        to_room,
                        subject,
                    )
                    return True
                return False
        except Exception:
            logger.debug(
                "RelayOutboxWorker: P2P failed %s → %s",
                self.project,
                to_room,
            )
            return False
