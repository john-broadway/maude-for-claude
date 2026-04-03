# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for ConciergeLogger — async fire-and-forget conversation logging."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.coordination.web.chat.logger import INSERT_SQL, ConciergeLogger


@pytest.fixture
def mock_pool():
    """LazyPool mock that returns an asyncpg pool."""
    pool = MagicMock()
    inner = AsyncMock()
    pool.get = AsyncMock(return_value=inner)
    return pool


@pytest.fixture
def logger(mock_pool):
    return ConciergeLogger(mock_pool)


# ── Basic logging ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_log_writes_to_agent_memory(logger, mock_pool):
    """Conversation is written to agent_memory with correct fields."""
    messages = [
        {"role": "user", "content": "What's the status of monitoring?"},
        {"role": "assistant", "content": "Monitoring is healthy."},
    ]

    await logger.log(
        session_id="sess-123",
        messages=messages,
        routing={"department": "it", "agent_name": "Patch", "confidence": 0.85},
        tokens_used=150,
        model="maude-agent",
    )

    inner = await mock_pool.get()
    inner.execute.assert_awaited_once()
    call_args = inner.execute.call_args
    assert call_args[0][0] == INSERT_SQL
    assert call_args[0][1] == "maude"  # project
    assert call_args[0][2] == "concierge"  # memory_type
    assert call_args[0][3] == "web_chat"  # trigger

    context = json.loads(call_args[0][4])
    assert context["session_id"] == "sess-123"
    assert context["department"] == "it"
    assert context["agent_name"] == "Patch"
    assert context["confidence"] == 0.85

    assert call_args[0][5] == "agency_routed"  # outcome
    assert call_args[0][6] == "What's the status of monitoring?"  # summary
    assert call_args[0][7] == 150  # tokens_used
    assert call_args[0][8] == "maude-agent"  # model


@pytest.mark.asyncio
async def test_log_without_routing_marks_completed(logger, mock_pool):
    """Conversations without agency routing get outcome='completed'."""
    messages = [
        {"role": "user", "content": "Show me room status"},
        {"role": "assistant", "content": "All rooms healthy."},
    ]

    await logger.log(session_id="sess-456", messages=messages)

    inner = await mock_pool.get()
    call_args = inner.execute.call_args
    assert call_args[0][5] == "completed"  # outcome

    context = json.loads(call_args[0][4])
    assert context["department"] is None


@pytest.mark.asyncio
async def test_log_summary_truncated(logger, mock_pool):
    """Summary is truncated to 200 characters."""
    long_msg = "x" * 500
    messages = [{"role": "user", "content": long_msg}]

    await logger.log(session_id="sess-789", messages=messages)

    inner = await mock_pool.get()
    call_args = inner.execute.call_args
    summary = call_args[0][6]
    assert len(summary) == 200


# ── Error handling ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_log_handles_pool_unavailable(mock_pool):
    """Logger degrades gracefully when PG pool is unavailable."""
    mock_pool.get = AsyncMock(return_value=None)
    lgr = ConciergeLogger(mock_pool)

    # Should not raise.
    await lgr.log(session_id="x", messages=[{"role": "user", "content": "hi"}])


@pytest.mark.asyncio
async def test_log_handles_execute_failure(logger, mock_pool):
    """Logger catches and logs execute errors."""
    inner = await mock_pool.get()
    inner.execute = AsyncMock(side_effect=RuntimeError("PG down"))

    # Should not raise.
    await logger.log(session_id="x", messages=[{"role": "user", "content": "hi"}])


@pytest.mark.asyncio
async def test_log_empty_messages(logger, mock_pool):
    """Empty message list still writes (summary will be empty)."""
    await logger.log(session_id="empty", messages=[])

    inner = await mock_pool.get()
    call_args = inner.execute.call_args
    assert call_args[0][6] == ""  # summary


@pytest.mark.asyncio
async def test_log_conversation_serialized_as_json(logger, mock_pool):
    """Messages are JSON-serialized for the conversation column."""
    messages = [
        {"role": "user", "content": "test"},
        {"role": "assistant", "content": "response"},
    ]

    await logger.log(session_id="json-test", messages=messages)

    inner = await mock_pool.get()
    call_args = inner.execute.call_args
    conv_json = call_args[0][9]  # conversation param
    parsed = json.loads(conv_json)
    assert len(parsed) == 2
    assert parsed[0]["role"] == "user"
