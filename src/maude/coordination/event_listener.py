"""PG LISTEN event subscriber for real-time cross-room coordination.

Subscribes to the ``maude_events`` PostgreSQL channel (the same channel
that :class:`EventPublisher` writes to) and maintains a ring buffer of
recent events.  On ``health_status_changed`` events the listener
cross-references the :class:`DependencyGraph` to log downstream impact.

Usage::

    listener = EventListener(dsn_kwargs={...})
    await listener.start()
    recent = listener.recent_events(limit=20, room="example-scada")
    await listener.stop()
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections import deque
from datetime import datetime, timezone
from typing import Any

import asyncpg

from maude.daemon.common import pg_pool_kwargs

logger = logging.getLogger(__name__)

# Lazy-import to avoid circular imports at module level
_CorrelationEngine = None

CHANNEL = "maude_events"

_RECONNECT_BASE = 1.0  # Initial backoff in seconds
_RECONNECT_CAP = 60.0  # Maximum backoff in seconds


class EventListener:
    """Real-time PG LISTEN subscriber for Maude events.

    Args:
        dsn_kwargs: asyncpg.connect keyword arguments.  If *None* the
            listener builds its own from ``~/.credentials/secrets.yaml``
            (or ``AMC_CREDENTIALS_PATH``).
        dependency_graph: Optional :class:`DependencyGraph` for downstream
            impact analysis on health events.
        buffer_size: Maximum events to keep in the ring buffer.
        relay: Optional :class:`Relay` instance for cross-room incident
            notifications. When provided, correlated incidents and upstream
            failures trigger relay messages to affected rooms.
    """

    def __init__(
        self,
        dsn_kwargs: dict[str, Any] | None = None,
        dependency_graph: Any | None = None,
        buffer_size: int = 500,
        relay: Any | None = None,
    ) -> None:
        self._dsn_kwargs = dsn_kwargs or self._default_dsn()
        self._deps = dependency_graph
        self._relay = relay
        self._buffer: deque[dict[str, Any]] = deque(maxlen=buffer_size)
        self._conn: asyncpg.Connection | None = None
        self._running = False
        self._reconnect_task: asyncio.Task[None] | None = None
        self._sweep_task: asyncio.Task[None] | None = None
        self._sweep_event = asyncio.Event()

        # Correlation engine for cross-room incident detection (Phase 2A)
        self._correlation: Any = None
        if dependency_graph is not None:
            try:
                from maude.coordination.correlation import CorrelationEngine

                self._correlation = CorrelationEngine(dependency_graph)
                logger.info("CorrelationEngine initialized in EventListener")
            except ImportError:
                logger.debug("CorrelationEngine not available (non-fatal)")

    # ── lifecycle ─────────────────────────────────────────────────

    async def _connect(self) -> bool:
        """Establish PG connection and subscribe to the channel.

        Returns True on success, False on failure.
        """
        try:
            self._conn = await asyncpg.connect(**self._dsn_kwargs)
            await self._conn.add_listener(CHANNEL, self._on_notify)
            logger.info("EventListener connected — listening on %s", CHANNEL)
            return True
        except Exception:
            logger.warning("EventListener: failed to connect to PostgreSQL")
            self._conn = None
            return False

    async def _reconnect_loop(self) -> None:
        """Background task: reconnect with exponential backoff on connection loss."""
        delay = _RECONNECT_BASE
        while self._running:
            # Check if connection is alive
            if self._conn is not None:
                try:
                    await self._conn.fetchval("SELECT 1")
                    delay = _RECONNECT_BASE  # reset on healthy check
                    await asyncio.sleep(5.0)  # poll interval
                    continue
                except Exception:
                    logger.warning("EventListener: PG connection lost, reconnecting...")
                    try:
                        await self._conn.close()
                    except Exception:
                        pass
                    self._conn = None

            # Connection is down — attempt reconnect with backoff
            if await self._connect():
                delay = _RECONNECT_BASE
                continue

            logger.warning("EventListener: reconnect failed, retrying in %.0fs", delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, _RECONNECT_CAP)

    async def start(self) -> None:
        """Connect to PostgreSQL and begin listening on *maude_events*."""
        if self._running:
            return
        self._running = True
        if not await self._connect():
            logger.warning("EventListener: initial connect failed, will retry in background")
        self._reconnect_task = asyncio.create_task(self._reconnect_loop())
        self._sweep_task = asyncio.create_task(self._sweep_loop())

    async def _sweep_loop(self) -> None:
        """Sweep stale relay tasks, triggered by incoming events."""
        while self._running:
            await self._sweep_event.wait()
            self._sweep_event.clear()
            if self._relay:
                try:
                    await self._relay.sweep_stale()
                except Exception:
                    logger.debug("Relay sweep failed (non-fatal)")

    async def stop(self) -> None:
        """Remove the listener and close the connection."""
        self._running = False
        for task_attr in ("_reconnect_task", "_sweep_task"):
            task = getattr(self, task_attr, None)
            if task is not None:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
                setattr(self, task_attr, None)
        if self._conn is not None:
            try:
                await self._conn.remove_listener(CHANNEL, self._on_notify)
                await self._conn.close()
            except Exception:
                pass
            self._conn = None
        logger.info("EventListener stopped")

    # ── notification handler ─────────────────────────────────────

    def _on_notify(
        self,
        conn: asyncpg.Connection[Any] | asyncpg.pool.PoolConnectionProxy[Any],
        pid: int,
        channel: str,
        payload: object,
    ) -> None:
        """Callback invoked by asyncpg on every NOTIFY."""
        payload_str = str(payload)
        try:
            event = json.loads(payload_str)
        except (json.JSONDecodeError, TypeError):
            logger.debug("EventListener: unparseable payload: %s", payload_str[:200])
            return

        event["received_at"] = datetime.now(timezone.utc).isoformat()
        self._sweep_event.set()
        self._buffer.append(event)

        # Feed events to CorrelationEngine for cross-room incident detection
        if self._correlation:
            room = event.get("room", "")
            event_type = event.get("event", "")
            if room and event_type:
                self._correlation.record_event(
                    room=room,
                    event_type=event_type,
                    data=event.get("data"),
                )
                correlated = self._correlation.check_correlation(room)
                if correlated:
                    logger.warning(
                        "Correlated incident detected: root=%s affecting %s (score=%.2f)",
                        correlated.root_room,
                        ", ".join(correlated.affected_rooms),
                        correlated.correlation_score,
                    )
                    if self._relay is not None:
                        msg = (
                            f"Correlated incident detected "
                            f"(score={correlated.correlation_score:.2f}): "
                            f"root={correlated.root_room}, "
                            f"affected={', '.join(correlated.affected_rooms)}"
                        )
                        targets = [correlated.root_room, *correlated.affected_rooms]
                        asyncio.ensure_future(
                            self._relay_batch("Correlated Incident Alert", msg, targets)
                        )

        # Dependency propagation for health changes
        if event.get("event") == "health_status_changed" and self._deps:
            room = event.get("room", "")
            status = (event.get("data") or {}).get("status", "")
            if status == "unhealthy":
                affected = self._deps.affected_by(room)
                if affected:
                    logger.warning(
                        "Room %s unhealthy — affected downstream: %s",
                        room,
                        ", ".join(affected),
                    )
                    if self._relay is not None:
                        msg = f"Upstream room {room!r} is unhealthy — check your dependencies."
                        asyncio.ensure_future(
                            self._relay_batch("Upstream Unhealthy", msg, affected)
                        )

    # ── query ─────────────────────────────────────────────────────

    async def _relay_one(self, target: str, subject: str, msg: str, timeout: float) -> None:
        """Send one relay message with per-room timeout."""
        if not self._relay:
            return
        try:
            await asyncio.wait_for(
                self._relay.send_lenient("coordinator", target, subject, msg),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            logger.warning("Relay to %s timed out after %.0fs", target, timeout)
        except Exception as e:
            logger.warning("Relay to %s failed: %s", target, e)

    async def _relay_batch(
        self,
        subject: str,
        msg: str,
        targets: list[str],
        timeout: float = 10.0,
    ) -> None:
        """Send relay messages to multiple rooms, each with its own timeout."""
        if not self._relay:
            return
        await asyncio.gather(
            *(self._relay_one(t, subject, msg, timeout) for t in targets),
        )

    def recent_events(
        self,
        limit: int = 50,
        room: str | None = None,
        event_type: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return recent events from the ring buffer.

        Args:
            limit: Maximum events to return.
            room: Filter to a specific room name.
            event_type: Filter to a specific event type string.

        Returns:
            List of event dicts, newest last.
        """
        events: list[dict[str, Any]] = list(self._buffer)
        if room:
            events = [e for e in events if e.get("room") == room]
        if event_type:
            events = [e for e in events if e.get("event") == event_type]
        return events[-limit:]

    @property
    def is_running(self) -> bool:
        """Whether the listener is actively subscribed."""
        return self._running

    @property
    def buffer_size(self) -> int:
        """Number of events currently in the ring buffer."""
        return len(self._buffer)

    # ── helpers ───────────────────────────────────────────────────

    @staticmethod
    def _default_dsn() -> dict[str, Any]:
        """Build asyncpg connect kwargs from credentials file."""
        try:
            kwargs = pg_pool_kwargs(database="agent")
            kwargs.pop("min_size", None)
            kwargs.pop("max_size", None)
            return kwargs
        except Exception:
            return {
                "host": "192.0.2.30",
                "port": 5432,
                "database": "agent",
                "user": "support",
                "password": "",
            }
