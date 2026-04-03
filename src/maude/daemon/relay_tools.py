# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Per-room relay tools — A2A communication for Room Agents.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Per-room relay tools for A2A inter-room communication.

Registers 5 identity-scoped relay tools on a Room's MCP server so its
Room Agent can send tasks to other Rooms and manage its own inbox.

Resilience: when PG is unreachable, ``relay_send`` buffers messages in
a local SQLite outbox. The ``RelayOutboxWorker`` (started by lifecycle)
drains the outbox to PG or falls back to P2P HTTP delivery.

Constitutional basis:
- Art. II.3: Communication through sanctioned interfaces (relay table + P2P MCP)
- Art. III.1: All actions audited (relay_tasks table + PG NOTIFY + local audit)
- Art. III.2: Identity mandatory (from_room hardcoded to self)
- Art. IV.3: Consent explicit (accept/reject flow)
- Art. VIII.1: Guards on write ops (rate limiting on send)

Identity scoping:
- ``relay_send`` hardcodes ``from_room`` to this room's project name
- ``relay_accept``/``relay_update`` only operate on tasks where
  ``to_room`` matches this room — enforced by the Relay class
- A Room cannot impersonate another Room

Usage::

    from maude.daemon.relay_tools import register_relay_tools
    register_relay_tools(mcp, audit, "my-service")

    # With local buffer support (requires LocalStore):
    register_relay_tools(mcp, audit, "my-service", local_store=local_store)
"""

import logging
from typing import Any

from maude.daemon.guards import audit_logged, rate_limited
from maude.db import format_json

logger = logging.getLogger(__name__)


def register_relay_tools(
    mcp: Any,
    audit: Any,
    project: str,
    *,
    local_store: Any | None = None,
) -> None:
    """Register 5 identity-scoped relay tools on a Room's MCP server.

    Tools registered:
        relay_send             — send a task FROM this room to another room
        relay_accept           — accept a task addressed TO this room
        relay_update           — update a task addressed TO this room
        relay_inbox            — view this room's incoming tasks
        relay_accept_incoming  — P2P receive (direct HTTP from another room)

    Args:
        mcp: FastMCP instance to register tools on.
        audit: AuditLogger for audit trail.
        project: This room's project name (identity).
        local_store: Optional LocalStore for outbox buffering on PG failure.
    """
    from maude.coordination.relay import Relay

    relay = Relay()

    # Create outbox if local_store is available
    outbox = None
    if local_store is not None:
        from maude.daemon.relay_buffer import RelayOutbox

        outbox = RelayOutbox(local_store, project)

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=10.0)
    async def relay_send(
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> str:
        """Send a relay task to another Room.

        Identity-scoped: from_room is always this room. A Room can only
        send as itself (Art. III.2 — authorship mandatory).

        Resilient: if PG is unreachable, buffers locally in SQLite.
        The RelayOutboxWorker will drain to PG or deliver via P2P HTTP.

        Args:
            to_room: Destination room name.
            subject: Brief subject line.
            body: Task description or message.
            priority: Priority level (0=normal, higher=more urgent).

        Returns:
            JSON with task ID/local ID, delivery mode, and status.
        """
        try:
            task_id = await relay.send(project, to_room, subject, body, priority)
            return format_json(
                {
                    "task_id": task_id,
                    "from_room": project,
                    "to_room": to_room,
                    "subject": subject,
                    "status": "pending",
                    "delivery": "direct",
                }
            )
        except Exception:
            # PG unavailable — buffer locally
            if outbox:
                local_id = await outbox.enqueue(to_room, subject, body, priority)
                return format_json(
                    {
                        "local_id": local_id,
                        "from_room": project,
                        "to_room": to_room,
                        "subject": subject,
                        "status": "buffered",
                        "delivery": "buffered",
                    }
                )
            return format_json(
                {
                    "error": "PG unavailable and no local buffer configured",
                }
            )

    @mcp.tool()
    @audit_logged(audit)
    async def relay_accept(task_id: int) -> str:
        """Accept a relay task addressed to this Room.

        Transitions pending → accepted. Only tasks where to_room matches
        this room can be accepted (Art. IV.3 — consent is explicit).

        Args:
            task_id: The relay task ID to accept.

        Returns:
            JSON with updated task state.
        """
        try:
            task = await relay.accept(task_id, project)
            return format_json(task.to_dict())
        except (ValueError, Exception) as e:
            return format_json({"error": str(e)})

    @mcp.tool()
    @audit_logged(audit)
    async def relay_update(
        task_id: int,
        status: str,
        result: str = "",
    ) -> str:
        """Update a relay task addressed to this Room.

        Valid transitions: accepted → running, running → completed/failed,
        any non-terminal → cancelled.

        Args:
            task_id: The relay task ID.
            status: Target status (running, completed, failed, cancelled).
            result: Result text (for completed/failed).

        Returns:
            JSON with updated task state.
        """
        try:
            task = await relay.update(task_id, project, status, result)
            return format_json(task.to_dict())
        except (ValueError, Exception) as e:
            return format_json({"error": str(e)})

    @mcp.tool()
    @audit_logged(audit)
    async def relay_inbox(
        status: str = "",
        limit: int = 20,
        since_minutes: int = 60,
    ) -> str:
        """View this Room's incoming relay tasks.

        Shows tasks addressed to this room. Read-only — broadly authorized
        within the room's own domain (Art. VIII.2).

        Args:
            status: Filter by status (pending, accepted, running, etc.).
            limit: Maximum results. Defaults to 20.
            since_minutes: Lookback window in minutes. 0 = no limit.

        Returns:
            JSON list of relay tasks for this room.
        """
        try:
            tasks = await relay.tasks(
                room=project,
                status=status,
                limit=limit,
                since_minutes=since_minutes,
            )
            return format_json([t.to_dict() for t in tasks])
        except Exception as e:
            return format_json({"error": str(e), "tasks": []})

    @mcp.tool()
    @audit_logged(audit)
    async def relay_accept_incoming(
        from_room: str,
        subject: str,
        body: str,
    ) -> str:
        """Accept a relay message directly from another Room (P2P fallback).

        Used when PG is unavailable. The sending room delivers directly
        via HTTP POST to this room's MCP endpoint. The message is stored
        as a local memory entry (type ``relay_incoming``) for the Room
        Agent to process on its next scheduled check.

        Constitutional basis: Art. II.3 (sanctioned interface — this tool
        is the published receive endpoint for P2P relay).

        Args:
            from_room: The sending room's identity.
            subject: Brief subject line.
            body: Message or task description.

        Returns:
            JSON with acceptance status.
        """
        if local_store is not None:
            await local_store.store(
                memory_type="relay_incoming",
                summary=f"P2P relay from {from_room}: {subject}",
                trigger=f"relay_p2p:{from_room}",
                reasoning=body,
                outcome="pending",
                enqueue_sync=False,
            )
            logger.info(
                "P2P relay received: %s → %s [%s]",
                from_room,
                project,
                subject,
            )
            return format_json(
                {
                    "accepted": True,
                    "from_room": from_room,
                    "to_room": project,
                    "subject": subject,
                    "delivery": "p2p",
                }
            )
        return format_json(
            {
                "accepted": False,
                "error": "No local store configured to receive P2P relay",
            }
        )

    logger.info(
        "Registered 5 A2A relay tools for %s (relay_send, relay_accept, "
        "relay_update, relay_inbox, relay_accept_incoming)",
        project,
    )
