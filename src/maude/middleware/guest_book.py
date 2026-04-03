# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Guest Book — every visitor signs the book.

Batches external MCP tool calls into structured memory entries. The
Concierge middleware hands each call to GuestBook.record_call() after
audit logging. After an idle timeout (no new calls), the buffer is
flushed as a single "visit" memory to PostgreSQL + Qdrant.

Non-fatal: if memory storage fails, the MCP server continues normally.

Usage:
    from maude.middleware.guest_book import GuestBook

    book = GuestBook(project="my-service", memory=memory_store)
    await book.record_call("service_status", {}, '{"ok": true}', True, 42.0)
    # ... after 60s of silence, auto-flushes to memory
    await book.close()
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

# Tools that are never recorded in the guest book.
# memory_* tools: avoid recursion (guest book stores TO memory).
# kill_switch_* tools: admin ops, not visitor activity.
EXCLUDED_TOOLS: set[str] = {
    "memory_load_knowledge",
    "memory_store",
    "memory_recall_recent",
    "memory_recall_by_id",
    "memory_recall_similar",
    "memory_embed",
    "memory_save",
    "memory_brief",
    "kill_switch_status",
    "kill_switch_activate",
    "kill_switch_deactivate",
}


@dataclass
class ToolCall:
    """A single buffered tool call record."""

    tool: str
    arguments: dict
    result: str
    success: bool
    duration_ms: float
    timestamp: float = field(default_factory=time.monotonic)


class GuestBook:
    """Buffers visitor tool calls and flushes them as visit memories.

    On the first call of a new visit, loads recent memories from PostgreSQL
    and returns a passive briefing string. This gives visitors (Claude Code,
    agents) awareness of what the Room has been doing — without an LLM call.

    Args:
        project: Project identifier (e.g., "my-service").
        memory: MemoryStore instance for PostgreSQL + Qdrant writes.
        idle_timeout: Seconds of silence before auto-flush. Default 60.
        briefing_limit: Max recent memories to include in passive briefing.
    """

    def __init__(
        self,
        project: str,
        memory: "MemoryStore",  # type: ignore[name-defined]  # noqa: F821
        idle_timeout: float = 60.0,
        briefing_limit: int = 5,
    ) -> None:
        self.project = project
        self._memory = memory
        self._idle_timeout = idle_timeout
        self._briefing_limit = briefing_limit
        self._buffer: list[ToolCall] = []
        self._lock = asyncio.Lock()
        self._timer_handle: asyncio.TimerHandle | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._briefing_cache: str | None = None

    async def record_call(
        self,
        tool_name: str,
        params: dict,
        result: str,
        success: bool,
        duration_ms: float,
    ) -> None:
        """Buffer a tool call and reset the idle timer.

        Excluded tools (memory_*, kill_switch_*) are silently skipped.
        """
        if tool_name in EXCLUDED_TOOLS:
            return

        async with self._lock:
            is_first_call = len(self._buffer) == 0
            self._buffer.append(
                ToolCall(
                    tool=tool_name,
                    arguments=params,
                    result=result[:500],
                    success=success,
                    duration_ms=duration_ms,
                )
            )
            self._reset_timer()

        # Load passive briefing on first call of a new visit
        if is_first_call:
            self._briefing_cache = await self._load_briefing()

    async def get_briefing(self) -> str | None:
        """Return the passive briefing for this visit, then clear it.

        Called by ConciergeServices to prepend context to the first
        tool response. Returns None on subsequent calls in the same visit.
        """
        briefing = self._briefing_cache
        self._briefing_cache = None
        return briefing

    async def _load_briefing(self) -> str | None:
        """Load recent memories as a passive briefing string."""
        try:
            memories = await self._memory.recall_recent(
                self.project,
                limit=self._briefing_limit,
            )
            if not memories:
                return None

            lines = [f"[Room {self.project} — recent activity]"]
            for m in memories:
                ts = m.created_at.strftime("%m-%d %H:%M") if m.created_at else "?"
                lines.append(f"  [{ts}] {m.memory_type}: {m.summary[:120]}")
            return "\n".join(lines)
        except Exception:
            logger.debug("GuestBook: Passive briefing load failed (non-fatal)")
            return None

    def _reset_timer(self) -> None:
        """Cancel existing timer and schedule a new flush after idle_timeout."""
        if self._timer_handle is not None:
            self._timer_handle.cancel()
            self._timer_handle = None

        loop = self._get_loop()
        if loop is None:
            return

        self._timer_handle = loop.call_later(
            self._idle_timeout,
            lambda: asyncio.ensure_future(self._flush()),
        )

    def _get_loop(self) -> asyncio.AbstractEventLoop | None:
        """Get the running event loop, caching it for timer scheduling."""
        if self._loop is None:
            try:
                self._loop = asyncio.get_running_loop()
            except RuntimeError:
                return None
        return self._loop

    async def _flush(self) -> None:
        """Flush the buffer as a single visit memory."""
        async with self._lock:
            if not self._buffer:
                return
            calls = list(self._buffer)
            self._buffer.clear()
            if self._timer_handle is not None:
                self._timer_handle.cancel()
                self._timer_handle = None

        try:
            summary = _build_summary(calls)
            outcome = _classify_outcome(calls)
            actions = [
                {
                    "tool": c.tool,
                    "arguments": c.arguments,
                    "result": c.result,
                    "success": c.success,
                    "duration_ms": round(c.duration_ms, 1),
                }
                for c in calls
            ]
            context = {
                "caller": "claude-code",
                "tool_count": len(calls),
                "duration_total_ms": round(sum(c.duration_ms for c in calls), 1),
                "first_call": calls[0].tool,
                "last_call": calls[-1].tool,
            }

            mem_id = await self._memory.store_memory(
                project=self.project,
                memory_type="visit",
                summary=summary,
                trigger="guest_book",
                context=context,
                actions_taken=actions,
                outcome=outcome,
            )

            if mem_id is not None:
                await self._memory.embed_and_store(
                    memory_id=mem_id,
                    summary=summary,
                    memory_type="visit",
                    outcome=outcome,
                )
                logger.info(
                    "GuestBook: Flushed visit #%d for %s (%d calls)",
                    mem_id,
                    self.project,
                    len(calls),
                )
            else:
                logger.warning("GuestBook: Flush failed (PG unavailable)")
        except Exception:
            logger.exception("GuestBook: Flush error (non-fatal)")

    async def flush_if_buffered(self) -> None:
        """Force flush if there are buffered calls. Call on shutdown."""
        async with self._lock:
            has_data = len(self._buffer) > 0
        if has_data:
            await self._flush()

    async def close(self) -> None:
        """Flush remaining calls and clean up."""
        await self.flush_if_buffered()
        if self._timer_handle is not None:
            self._timer_handle.cancel()
            self._timer_handle = None


def _classify_outcome(calls: list[ToolCall]) -> str:
    """Classify the visit outcome based on success rates."""
    if not calls:
        return "empty"
    successes = sum(1 for c in calls if c.success)
    if successes == len(calls):
        return "completed"
    if successes == 0:
        return "failed"
    return "mixed"


def _build_summary(calls: list[ToolCall]) -> str:
    """Build a template-based summary from buffered calls."""
    tool_names = list(dict.fromkeys(c.tool for c in calls))  # unique, ordered
    total_ms = sum(c.duration_ms for c in calls)
    successes = sum(1 for c in calls if c.success)

    return (
        f"Visitor session: {len(calls)} tool(s) called over {total_ms / 1000:.1f}s. "
        f"Tools: {', '.join(tool_names)}. "
        f"Success rate: {successes}/{len(calls)}."
    )
