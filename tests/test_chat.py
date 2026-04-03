# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Maude chat agent and session management."""

import json
import time
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.coordination.web.chat import (
    CHAT_TOOLS,
    SYSTEM_PROMPT,
    ChatAgent,
    ChatSession,
    ChatSessionStore,
)
from maude.llm.router import LLMResponse, ToolCall

# ── Session Store ─────────────────────────────────────────────────


def test_session_store_create_and_get():
    """Same session_id returns same session."""
    store = ChatSessionStore()
    s1 = store.get_or_create("abc")
    s2 = store.get_or_create("abc")
    assert s1 is s2
    assert s1.session_id == "abc"


def test_session_store_new_id():
    """New id creates new session."""
    store = ChatSessionStore()
    s1 = store.get_or_create("a")
    s2 = store.get_or_create("b")
    assert s1 is not s2
    assert s1.session_id == "a"
    assert s2.session_id == "b"


def test_session_store_empty_id_generates_uuid():
    """Empty session_id generates a UUID."""
    store = ChatSessionStore()
    s = store.get_or_create("")
    assert len(s.session_id) > 0
    assert s.session_id != ""


def test_session_store_eviction():
    """Stale sessions are removed by evict_stale."""
    store = ChatSessionStore(ttl_minutes=1)
    s = store.get_or_create("old")
    s.last_active = time.time() - 120  # 2 min ago
    store.get_or_create("new")

    count = store.evict_stale()
    assert count == 1
    # "new" should survive, "old" should be gone
    s_new = store.get_or_create("new")
    assert s_new.session_id == "new"


def test_session_store_max_sessions_eviction():
    """Sessions beyond max_sessions are evicted oldest-first."""
    store = ChatSessionStore(max_sessions=2, ttl_minutes=60)
    store.get_or_create("a").last_active = time.time() - 30
    store.get_or_create("b").last_active = time.time() - 20
    store.get_or_create("c").last_active = time.time() - 10

    store.evict_stale()
    # Should keep only 2 newest (b, c)
    assert store.get_or_create("c").messages == []


def test_session_max_messages_trimmed():
    """Oldest messages dropped at cap."""
    store = ChatSessionStore(max_messages=3)
    s = store.get_or_create("x")
    for i in range(5):
        s.messages.append({"role": "user", "content": f"msg-{i}"})

    store.trim_messages(s)
    assert len(s.messages) == 3
    assert s.messages[0]["content"] == "msg-2"


def test_session_clear():
    """Clearing a session empties its messages."""
    store = ChatSessionStore()
    s = store.get_or_create("x")
    s.messages.append({"role": "user", "content": "hello"})
    store.clear("x")
    assert len(s.messages) == 0


# ── Chat Agent ────────────────────────────────────────────────────


@pytest.fixture
def mock_llm():
    return AsyncMock()


@pytest.fixture
def mock_memory():
    m = AsyncMock()
    m.recent_incidents = AsyncMock(return_value=[])
    m.recent_escalations = AsyncMock(return_value=[])
    m.recent_restarts = AsyncMock(return_value=[])
    return m


@pytest.fixture
def mock_deps():
    d = MagicMock()
    d.depends_on.return_value = ["postgresql"]
    d.depended_by.return_value = ["hmi"]
    d.affected_by.return_value = ["hmi", "monitoring"]
    return d


@pytest.fixture
def mock_briefing():
    b = AsyncMock()
    b.generate = AsyncMock(return_value="== Briefing ==")
    b.room_status = AsyncMock(return_value="ROOM STATUS GRID")
    return b


@pytest.fixture
def agent(mock_llm, mock_memory, mock_deps, mock_briefing):
    return ChatAgent(
        llm=mock_llm,
        memory=mock_memory,
        deps=mock_deps,
        briefing=mock_briefing,
        max_iterations=5,
    )


async def _collect(agent: ChatAgent, session: ChatSession, msg: str) -> list[dict]:
    """Collect all SSE events from agent.respond()."""
    events = []
    async for chunk in agent.respond(session, msg):
        events.append(json.loads(chunk))
    return events


@pytest.mark.asyncio
async def test_chat_agent_simple_response(agent, mock_llm):
    """Simple text response with no tool calls."""
    mock_llm.send = AsyncMock(return_value=LLMResponse(
        content="All rooms are operational.",
        tool_calls=[],
        model="test",
        tokens_used=50,
    ))
    session = ChatSession(session_id="test-1")
    events = await _collect(agent, session, "How are the rooms?")

    assert any(e["type"] == "text" for e in events)
    assert any(e["type"] == "done" for e in events)
    text_events = [e for e in events if e["type"] == "text"]
    assert "operational" in text_events[0]["content"]


@pytest.mark.asyncio
async def test_chat_agent_tool_call_and_response(agent, mock_llm, mock_briefing):
    """Tool call → dispatch → second LLM call returns text."""
    # First call: LLM returns a tool call
    tool_response = LLMResponse(
        content="",
        tool_calls=[ToolCall(id="tc1", name="room_status", arguments={"minutes": 60})],
        model="test",
        tokens_used=30,
    )
    # Second call: LLM returns text
    text_response = LLMResponse(
        content="All rooms look good.",
        tool_calls=[],
        model="test",
        tokens_used=40,
    )
    mock_llm.send = AsyncMock(side_effect=[tool_response, text_response])

    session = ChatSession(session_id="test-2")
    events = await _collect(agent, session, "Status?")

    types = [e["type"] for e in events]
    assert "tool_call" in types
    assert "text" in types
    assert "done" in types
    mock_briefing.room_status.assert_awaited_once_with(minutes=60)


@pytest.mark.asyncio
async def test_chat_agent_room_status_dispatch(agent, mock_llm, mock_briefing):
    """room_status tool dispatches to briefing.room_status."""
    mock_llm.send = AsyncMock(side_effect=[
        LLMResponse(content="", tool_calls=[
            ToolCall(id="tc1", name="room_status", arguments={})
        ], model="test", tokens_used=10),
        LLMResponse(content="Here's the status.", tool_calls=[], model="test", tokens_used=20),
    ])
    session = ChatSession(session_id="test-3")
    await _collect(agent, session, "rooms?")
    mock_briefing.room_status.assert_awaited_once()


@pytest.mark.asyncio
async def test_chat_agent_incidents_dispatch(agent, mock_llm, mock_memory):
    """recent_incidents dispatches to memory.recent_incidents."""
    mock_llm.send = AsyncMock(side_effect=[
        LLMResponse(content="", tool_calls=[
            ToolCall(id="tc1", name="recent_incidents", arguments={"minutes": 30})
        ], model="test", tokens_used=10),
        LLMResponse(content="No incidents.", tool_calls=[], model="test", tokens_used=20),
    ])
    session = ChatSession(session_id="test-4")
    await _collect(agent, session, "any incidents?")
    mock_memory.recent_incidents.assert_awaited_with(minutes=30)


@pytest.mark.asyncio
async def test_chat_agent_briefing_dispatch(agent, mock_llm, mock_briefing):
    """hotel_briefing dispatches to briefing.generate."""
    mock_llm.send = AsyncMock(side_effect=[
        LLMResponse(content="", tool_calls=[
            ToolCall(id="tc1", name="hotel_briefing", arguments={"scope": "all", "minutes": 120})
        ], model="test", tokens_used=10),
        LLMResponse(content="Here's the briefing.", tool_calls=[], model="test", tokens_used=30),
    ])
    session = ChatSession(session_id="test-5")
    await _collect(agent, session, "briefing please")
    mock_briefing.generate.assert_awaited_with(scope="all", minutes=120)


@pytest.mark.asyncio
async def test_chat_agent_dependency_dispatch(agent, mock_llm, mock_deps):
    """room_dependencies dispatches to DependencyGraph methods."""
    mock_llm.send = AsyncMock(side_effect=[
        LLMResponse(content="", tool_calls=[
            ToolCall(id="tc1", name="room_dependencies", arguments={"room": "my-service"})
        ], model="test", tokens_used=10),
        LLMResponse(content="Collector deps.", tool_calls=[], model="test", tokens_used=20),
    ])
    session = ChatSession(session_id="test-6")
    await _collect(agent, session, "what does collector depend on?")
    mock_deps.depends_on.assert_called_with("my-service")
    mock_deps.depended_by.assert_called_with("my-service")
    mock_deps.affected_by.assert_called_with("my-service")


@pytest.mark.asyncio
async def test_chat_agent_max_iterations(agent, mock_llm):
    """Stops after max iterations if LLM keeps calling tools."""
    mock_llm.send = AsyncMock(return_value=LLMResponse(
        content="",
        tool_calls=[ToolCall(id="tc1", name="room_status", arguments={})],
        model="test",
        tokens_used=10,
    ))
    agent._max_iterations = 3
    session = ChatSession(session_id="test-7")
    events = await _collect(agent, session, "loop forever")

    # Should get tool_call events for each iteration, then a final text + done
    done_events = [e for e in events if e["type"] == "done"]
    assert len(done_events) == 1
    # Should have gotten a "unable to complete" message
    text_events = [e for e in events if e["type"] == "text"]
    assert any("unable" in e["content"].lower() for e in text_events)


@pytest.mark.asyncio
async def test_chat_agent_llm_failure(agent, mock_llm):
    """LLM returns None — yields error event."""
    mock_llm.send = AsyncMock(return_value=None)
    session = ChatSession(session_id="test-8")
    events = await _collect(agent, session, "hello")

    error_events = [e for e in events if e["type"] == "error"]
    assert len(error_events) == 1
    assert "unavailable" in error_events[0]["content"].lower()


@pytest.mark.asyncio
async def test_chat_agent_system_prompt_has_persona():
    """System prompt contains Maude persona elements."""
    assert "Maude" in SYSTEM_PROMPT
    assert "Maude" in SYSTEM_PROMPT
    assert "concierge" in SYSTEM_PROMPT


def test_chat_tool_schemas_are_valid():
    """All 10 tools (6 hotel + 4 agency) have required schema fields."""
    assert len(CHAT_TOOLS) == 10
    for tool in CHAT_TOOLS:
        assert "name" in tool
        assert "description" in tool
        assert "parameters" in tool
        assert tool["parameters"]["type"] == "object"
