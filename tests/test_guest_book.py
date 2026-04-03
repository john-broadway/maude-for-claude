# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for GuestBook — visitor tool call batching into visit memories."""

import asyncio
from unittest.mock import AsyncMock

import pytest

from maude.middleware.guest_book import (
    EXCLUDED_TOOLS,
    GuestBook,
    ToolCall,
    _build_summary,
    _classify_outcome,
)


@pytest.fixture
def mock_memory() -> AsyncMock:
    """Mock MemoryStore that returns a fake row ID."""
    memory = AsyncMock()
    memory.store_memory = AsyncMock(return_value=42)
    memory.embed_and_store = AsyncMock(return_value=True)
    return memory


@pytest.fixture
def guest_book(mock_memory: AsyncMock) -> GuestBook:
    """GuestBook with a short idle timeout for testing."""
    return GuestBook(project="test-project", memory=mock_memory, idle_timeout=0.2)


# --- Exclusion tests ---


@pytest.mark.asyncio
async def test_excluded_tools_not_buffered(guest_book: GuestBook) -> None:
    """Memory and kill_switch tools should be silently skipped."""
    for tool in EXCLUDED_TOOLS:
        await guest_book.record_call(tool, {}, "ok", True, 10.0)

    # Nothing buffered — flush should be a no-op
    await guest_book.flush_if_buffered()
    guest_book._memory.store_memory.assert_not_called()


@pytest.mark.asyncio
async def test_normal_tool_is_buffered(guest_book: GuestBook) -> None:
    """Non-excluded tools should be buffered."""
    await guest_book.record_call("service_status", {}, "ok", True, 15.0)

    async with guest_book._lock:
        assert len(guest_book._buffer) == 1
        assert guest_book._buffer[0].tool == "service_status"


# --- Batching tests ---


@pytest.mark.asyncio
async def test_multiple_calls_batched_into_single_memory(
    guest_book: GuestBook, mock_memory: AsyncMock,
) -> None:
    """Multiple calls within timeout should produce a single memory entry."""
    await guest_book.record_call("service_status", {}, "ok", True, 10.0)
    await guest_book.record_call("service_health", {}, "ok", True, 20.0)
    await guest_book.record_call("service_logs", {"lines": 50}, "logs...", True, 30.0)

    await guest_book.flush_if_buffered()

    mock_memory.store_memory.assert_called_once()
    call_kwargs = mock_memory.store_memory.call_args.kwargs
    assert call_kwargs["memory_type"] == "visit"
    assert call_kwargs["trigger"] == "guest_book"
    assert call_kwargs["project"] == "test-project"
    assert len(call_kwargs["actions_taken"]) == 3


# --- Idle timeout tests ---


@pytest.mark.asyncio
async def test_idle_timeout_fires(
    guest_book: GuestBook, mock_memory: AsyncMock,
) -> None:
    """After idle_timeout seconds of silence, buffer should auto-flush."""
    await guest_book.record_call("service_status", {}, "ok", True, 10.0)

    # Wait for the idle timeout to fire (0.2s + margin)
    await asyncio.sleep(0.4)

    mock_memory.store_memory.assert_called_once()
    mock_memory.embed_and_store.assert_called_once()

    # Buffer should be empty now
    async with guest_book._lock:
        assert len(guest_book._buffer) == 0


@pytest.mark.asyncio
async def test_timer_resets_on_new_call(
    guest_book: GuestBook, mock_memory: AsyncMock,
) -> None:
    """New calls should reset the idle timer, delaying the flush."""
    await guest_book.record_call("service_status", {}, "ok", True, 10.0)
    await asyncio.sleep(0.1)  # Halfway through timeout
    await guest_book.record_call("service_health", {}, "ok", True, 20.0)
    await asyncio.sleep(0.1)  # Still within timeout from second call

    # Should NOT have flushed yet
    mock_memory.store_memory.assert_not_called()

    # Now wait for the timeout from the second call
    await asyncio.sleep(0.2)
    mock_memory.store_memory.assert_called_once()

    # Both calls should be in the single flush
    call_kwargs = mock_memory.store_memory.call_args.kwargs
    assert len(call_kwargs["actions_taken"]) == 2


# --- Shutdown flush tests ---


@pytest.mark.asyncio
async def test_flush_on_shutdown(
    guest_book: GuestBook, mock_memory: AsyncMock,
) -> None:
    """flush_if_buffered captures incomplete visits on shutdown."""
    await guest_book.record_call("service_status", {}, "ok", True, 10.0)

    # Shutdown without waiting for timer
    await guest_book.close()

    mock_memory.store_memory.assert_called_once()


@pytest.mark.asyncio
async def test_flush_if_buffered_noop_when_empty(
    guest_book: GuestBook, mock_memory: AsyncMock,
) -> None:
    """flush_if_buffered should be a no-op with empty buffer."""
    await guest_book.flush_if_buffered()
    mock_memory.store_memory.assert_not_called()


# --- Outcome classification tests ---


def test_outcome_completed() -> None:
    calls = [ToolCall("a", {}, "ok", True, 10.0), ToolCall("b", {}, "ok", True, 20.0)]
    assert _classify_outcome(calls) == "completed"


def test_outcome_failed() -> None:
    calls = [ToolCall("a", {}, "err", False, 10.0), ToolCall("b", {}, "err", False, 20.0)]
    assert _classify_outcome(calls) == "failed"


def test_outcome_mixed() -> None:
    calls = [ToolCall("a", {}, "ok", True, 10.0), ToolCall("b", {}, "err", False, 20.0)]
    assert _classify_outcome(calls) == "mixed"


def test_outcome_empty() -> None:
    assert _classify_outcome([]) == "empty"


# --- Summary generation tests ---


def test_summary_format() -> None:
    calls = [
        ToolCall("service_status", {}, "ok", True, 100.0),
        ToolCall("service_health", {}, "ok", True, 200.0),
        ToolCall("service_status", {}, "ok", True, 50.0),  # duplicate tool
    ]
    summary = _build_summary(calls)
    assert "3 tool(s)" in summary
    assert "service_status" in summary
    assert "service_health" in summary
    assert "3/3" in summary  # success rate
    assert "0.3s" in summary  # 350ms total → 0.35 → 0.3 with :.1f


def test_summary_deduplicates_tool_names() -> None:
    calls = [
        ToolCall("service_status", {}, "ok", True, 10.0),
        ToolCall("service_status", {}, "ok", True, 10.0),
    ]
    summary = _build_summary(calls)
    # "service_status" should appear once in the Tools list
    assert summary.count("service_status") == 1


# --- Graceful failure tests ---


@pytest.mark.asyncio
async def test_memory_failure_graceful(guest_book: GuestBook) -> None:
    """If PostgreSQL is down, flush should log and continue, not crash."""
    guest_book._memory.store_memory = AsyncMock(return_value=None)

    await guest_book.record_call("service_status", {}, "ok", True, 10.0)
    await guest_book.flush_if_buffered()

    # Should not raise, and embed should not be called (no mem_id)
    guest_book._memory.embed_and_store.assert_not_called()


@pytest.mark.asyncio
async def test_embed_failure_graceful(guest_book: GuestBook) -> None:
    """If Qdrant is down, flush should still succeed for PG part."""
    guest_book._memory.embed_and_store = AsyncMock(side_effect=Exception("Qdrant down"))

    await guest_book.record_call("service_status", {}, "ok", True, 10.0)
    # Should not raise
    await guest_book.flush_if_buffered()

    guest_book._memory.store_memory.assert_called_once()


# --- get_briefing returns cached then clears (lines 126-128) ---


@pytest.mark.asyncio
async def test_get_briefing_returns_cached_then_clears(guest_book: GuestBook) -> None:
    """get_briefing returns the cached briefing once, then None."""
    guest_book._briefing_cache = "some briefing text"
    result = await guest_book.get_briefing()
    assert result == "some briefing text"

    # Second call returns None
    result2 = await guest_book.get_briefing()
    assert result2 is None


# --- _load_briefing with memories (lines 137, 141-142, 144-146) ---


@pytest.mark.asyncio
async def test_load_briefing_with_memories(guest_book: GuestBook) -> None:
    """_load_briefing should format recent memories into a briefing string."""
    from datetime import datetime

    from maude.memory.store import Memory

    m = Memory(
        id=1, project="test-project", memory_type="visit",
        summary="Checked service health and all was good",
        outcome="completed", created_at=datetime(2026, 2, 1, 14, 30),
    )
    guest_book._memory.recall_recent = AsyncMock(return_value=[m])

    result = await guest_book._load_briefing()
    assert result is not None
    assert "Room test-project" in result
    assert "visit" in result
    assert "Checked service" in result


@pytest.mark.asyncio
async def test_load_briefing_no_memories(guest_book: GuestBook) -> None:
    """_load_briefing returns None when no recent memories."""
    guest_book._memory.recall_recent = AsyncMock(return_value=[])
    result = await guest_book._load_briefing()
    assert result is None


@pytest.mark.asyncio
async def test_load_briefing_exception(guest_book: GuestBook) -> None:
    """_load_briefing returns None on exception."""
    guest_book._memory.recall_recent = AsyncMock(side_effect=Exception("DB down"))
    result = await guest_book._load_briefing()
    assert result is None


# --- _get_loop RuntimeError path (lines 168-169) ---


def test_get_loop_no_running_loop() -> None:
    """_get_loop returns None when no event loop is running."""
    # Create a fresh GuestBook outside any async context
    from unittest.mock import AsyncMock as AM
    book = GuestBook(project="test", memory=AM(), idle_timeout=60.0)
    book._loop = None  # ensure not cached
    # Calling from sync context — no running loop
    result = book._get_loop()
    assert result is None


# --- _flush with empty buffer (line 176) ---


@pytest.mark.asyncio
async def test_flush_empty_buffer_noop(guest_book: GuestBook) -> None:
    """_flush with empty buffer should be a no-op."""
    await guest_book._flush()
    guest_book._memory.store_memory.assert_not_called()


# --- _reset_timer with no running loop (line 156) ---


@pytest.mark.asyncio
async def test_reset_timer_no_loop(guest_book: GuestBook) -> None:
    """_reset_timer does nothing when _get_loop returns None."""
    guest_book._get_loop = lambda: None  # type: ignore[assignment]
    # Should not raise
    guest_book._reset_timer()
    assert guest_book._timer_handle is None
