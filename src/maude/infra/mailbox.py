# Maude Room Mailbox — lightweight fire-and-forget inter-room notifications.
# Version: 1.0.0
# Created: 2026-04-02 16:00 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Lightweight mailbox for inter-room notifications.

Complements the relay (which uses a full task state machine) with
simple fire-and-forget messages. Use cases: "I restarted PostgreSQL",
"disk at 85% on example-scada", "model updated on gpu-a".

Messages are stored in the ``room_mailbox`` PG table (auto-created via
DDL migration, not this module). Each message has a priority level
and a read_at timestamp for tracking.

Usage::

    mailbox = RoomMailbox(project="example-scada")
    await mailbox.send("postgresql", "I restarted — expect brief connection drops", priority="info")
    unread = await mailbox.check()
    await mailbox.mark_read([msg["id"] for msg in unread])
"""

from __future__ import annotations

import logging
from typing import Any

from maude.daemon.common import resolve_infra_hosts
from maude.db import PoolRegistry

logger = logging.getLogger(__name__)

# Valid priority levels (info < warning < critical)
PRIORITIES = ("info", "warning", "critical")

_SEND_SQL = """
INSERT INTO room_mailbox (from_room, to_room, message, priority)
VALUES ($1, $2, $3, $4)
RETURNING id
"""

_CHECK_SQL = """
SELECT id, from_room, to_room, message, priority, created_at
FROM room_mailbox
WHERE to_room = $1 AND read_at IS NULL
ORDER BY
    CASE priority
        WHEN 'critical' THEN 0
        WHEN 'warning' THEN 1
        ELSE 2
    END,
    created_at ASC
LIMIT $2
"""

_MARK_READ_SQL = """
UPDATE room_mailbox
SET read_at = now()
WHERE id = ANY($1) AND to_room = $2
"""

_UNREAD_COUNT_SQL = """
SELECT count(*) FROM room_mailbox
WHERE to_room = $1 AND read_at IS NULL
"""

_PRUNE_SQL = """
DELETE FROM room_mailbox
WHERE read_at IS NOT NULL
  AND read_at < now() - interval '7 days'
"""

# DDL reference (run as postgres superuser, not via this module):
# CREATE TABLE IF NOT EXISTS room_mailbox (
#     id SERIAL PRIMARY KEY,
#     from_room TEXT NOT NULL,
#     to_room TEXT NOT NULL,
#     message TEXT NOT NULL,
#     priority TEXT NOT NULL DEFAULT 'info',
#     read_at TIMESTAMPTZ,
#     created_at TIMESTAMPTZ DEFAULT now()
# );
# CREATE INDEX IF NOT EXISTS idx_mailbox_to_unread
#     ON room_mailbox (to_room) WHERE read_at IS NULL;


class RoomMailbox:
    """Fire-and-forget inter-room notification mailbox.

    Args:
        project: This room's project name (used as ``to_room`` for receiving).
        db_host: PostgreSQL host override.
        database: Database name. Defaults to "agent".
    """

    def __init__(
        self,
        project: str,
        db_host: str = "",
        database: str = "agent",
    ) -> None:
        self.project = project
        self.db_host = db_host or resolve_infra_hosts()["db"]
        self._db = PoolRegistry.get(database=database, db_host=self.db_host)

    async def send(
        self,
        to_room: str,
        message: str,
        priority: str = "info",
    ) -> int | None:
        """Send a notification to another room.

        Fire-and-forget: returns the message ID on success, None on failure.
        Never raises — the caller's operation should not fail because a
        notification couldn't be delivered.
        """
        if priority not in PRIORITIES:
            priority = "info"

        pool = await self._db.get()
        if pool is None:
            logger.debug("Mailbox: PG unavailable, notification to %s dropped", to_room)
            return None

        try:
            msg_id = await pool.fetchval(
                _SEND_SQL,
                self.project,
                to_room,
                message[:2000],  # cap message length
                priority,
            )
            logger.debug(
                "Mailbox: sent #%d from %s to %s (%s)",
                msg_id,
                self.project,
                to_room,
                priority,
            )
            return msg_id
        except Exception:
            logger.debug("Mailbox: failed to send to %s", to_room, exc_info=True)
            return None

    async def check(self, limit: int = 20) -> list[dict[str, Any]]:
        """Check for unread messages addressed to this room.

        Returns messages ordered by priority (critical first), then oldest first.
        """
        pool = await self._db.get()
        if pool is None:
            return []

        try:
            rows = await pool.fetch(_CHECK_SQL, self.project, limit)
            return [
                {
                    "id": row["id"],
                    "from": row["from_room"],
                    "message": row["message"],
                    "priority": row["priority"],
                    "created_at": row["created_at"].isoformat() if row["created_at"] else None,
                }
                for row in rows
            ]
        except Exception:
            logger.debug("Mailbox: check failed for %s", self.project, exc_info=True)
            return []

    async def mark_read(self, message_ids: list[int]) -> int:
        """Mark messages as read. Returns count of messages marked."""
        if not message_ids:
            return 0

        pool = await self._db.get()
        if pool is None:
            return 0

        try:
            result = await pool.execute(_MARK_READ_SQL, message_ids, self.project)
            count = int(result.split()[-1]) if result else 0
            return count
        except Exception:
            logger.debug("Mailbox: mark_read failed", exc_info=True)
            return 0

    async def unread_count(self) -> int:
        """Get count of unread messages for this room."""
        pool = await self._db.get()
        if pool is None:
            return 0

        try:
            count = await pool.fetchval(_UNREAD_COUNT_SQL, self.project)
            return count or 0
        except Exception:
            return 0

    async def prune_old(self) -> int:
        """Delete read messages older than 7 days. Returns count deleted."""
        pool = await self._db.get()
        if pool is None:
            return 0

        try:
            result = await pool.execute(_PRUNE_SQL)
            count = int(result.split()[-1]) if result else 0
            if count:
                logger.info("Mailbox: pruned %d old messages", count)
            return count
        except Exception:
            logger.debug("Mailbox: prune failed", exc_info=True)
            return 0

    async def format_briefing(self, limit: int = 10) -> str:
        """Format unread messages as a text briefing for the Room Agent.

        Returns empty string if no unread messages.
        """
        messages = await self.check(limit=limit)
        if not messages:
            return ""

        lines = [f"Mailbox: {len(messages)} unread notification(s):"]
        for msg in messages:
            priority_tag = f"[{msg['priority'].upper()}]" if msg["priority"] != "info" else ""
            lines.append(f"  - {priority_tag} From {msg['from']}: {msg['message']}")
        return "\n".join(lines)

    async def close(self) -> None:
        """Clean up the connection pool."""
        await self._db.close()
