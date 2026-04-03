"""Tests for room agent — the LLM-powered agent loop."""

from unittest.mock import AsyncMock, MagicMock, patch

from maude.healing.room_agent import RoomAgent, RoomAgentConfig, _VelocityTracker
from maude.llm.router import LLMResponse, ToolCall


def _make_agent(
    llm_responses: list[LLMResponse] | None = None,
    tool_results: dict[str, str] | None = None,
) -> RoomAgent:
    """Create a RoomAgent with mocked dependencies."""
    config = RoomAgentConfig(
        project="grafana",
        name="grafana",
        max_iterations=5,
        max_tokens=4096,
        tools=["service_status", "grafana_health"],
        memory={"postgresql": True, "qdrant": True, "recent_limit": 5, "similar_limit": 3},
        enabled=True,
    )

    # LLM router
    llm = AsyncMock()
    if llm_responses:
        llm.send = AsyncMock(side_effect=llm_responses)
    else:
        llm.send = AsyncMock(
            return_value=LLMResponse(content="All clear.", model="test", tokens_used=50)
        )

    # Tool registry
    tools = AsyncMock()
    tools.get_tool_schemas = AsyncMock(
        return_value=[
            {"name": "service_status", "description": "Check service", "parameters": {}},
        ]
    )
    _tool_results = tool_results or {"service_status": "active"}
    tools.call = AsyncMock(side_effect=lambda name, **kw: _tool_results.get(name, ""))
    tools.is_read_only = MagicMock(return_value=False)  # Sync method — not AsyncMock

    # Memory store
    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[])
    memory.recall_similar = AsyncMock(return_value=[])
    memory.store_memory = AsyncMock(return_value=1)
    memory.embed_and_store = AsyncMock(return_value=True)

    # Knowledge manager
    knowledge = AsyncMock()
    knowledge.git_pull = AsyncMock(return_value=True)
    knowledge.load_knowledge = AsyncMock(return_value="# Identity\nI am Room 204.")
    knowledge.update_memory = AsyncMock(return_value=True)
    knowledge.git_commit_push = AsyncMock(return_value=True)

    return RoomAgent(
        config=config,
        llm=llm,
        tools=tools,
        memory=memory,
        knowledge=knowledge,
    )


# ── Simple resolution (no tool calls) ──────────────────────────────


async def test_agent_no_action_without_tools():
    """When agent produces text but never calls tools, outcome is no_action."""
    agent = _make_agent()
    result = await agent.run("schedule check", {"type": "schedule"})

    assert result.success is True
    assert result.outcome == "no_action"
    assert "All clear." in result.summary
    assert result.iterations == 1
    assert result.actions == []


# ── Tool-use loop ───────────────────────────────────────────────────


async def test_agent_uses_tools_then_resolves():
    responses = [
        # First response: agent wants to call a tool
        LLMResponse(
            content="Let me check.",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=30,
        ),
        # Second response: agent is done
        LLMResponse(
            content="Service is active. All clear.",
            tool_calls=[],
            model="test",
            tokens_used=40,
        ),
    ]

    agent = _make_agent(llm_responses=responses)
    result = await agent.run("health_loop_escalation", {"reason": "test"})

    assert result.success is True
    assert result.outcome == "resolved"
    assert result.iterations == 2
    assert len(result.actions) == 1
    assert result.actions[0]["tool"] == "service_status"
    assert result.tokens_used == 70


# ── Max iterations hit ──────────────────────────────────────────────


async def test_agent_escalates_at_max_iterations():
    # Agent keeps requesting tools forever
    tool_response = LLMResponse(
        content="Checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=10,
    )
    responses = [tool_response] * 5  # 5 iterations = max

    agent = _make_agent(llm_responses=responses)
    result = await agent.run("stuck_issue")

    assert result.outcome == "escalated"
    assert result.iterations == 5
    assert not result.success


# ── LLM returns None (all backends failed) ──────────────────────────


async def test_agent_handles_llm_failure():
    agent = _make_agent()
    agent.llm.send = AsyncMock(return_value=None)

    result = await agent.run("test trigger")

    assert result.outcome == "failed"
    assert "unavailable" in result.summary.lower()
    assert not result.success


# ── Memory storage ──────────────────────────────────────────────────


async def test_agent_skips_storage_for_no_action_checks():
    agent = _make_agent()
    await agent.run("scheduled_check")

    # check/no_action results from health triggers skip storage to prevent noise
    agent.memory.store_memory.assert_not_called()
    agent.memory.embed_and_store.assert_not_called()
    # Scheduled checks with no tool calls are marked failed (not no_action)
    result = await agent.run("scheduled_check")
    assert result.outcome == "failed"
    assert not result.success


async def test_agent_stores_incident_memory_with_tools():
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_restart", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="Resolved the issue.",
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    await agent.run("health_loop_escalation")

    call_kwargs = agent.memory.store_memory.call_args[1]
    assert call_kwargs["memory_type"] == "incident"  # resolved with mutating action → incident

    # Knowledge files updated for resolved incidents
    agent.knowledge.update_memory.assert_called_once()
    agent.knowledge.git_commit_push.assert_called_once()


# ── Knowledge loading ───────────────────────────────────────────────


async def test_agent_pulls_knowledge_before_run():
    agent = _make_agent()
    await agent.run("test")

    agent.knowledge.git_pull.assert_called_once()
    agent.knowledge.load_knowledge.assert_called_once()


# ── Context enrichment ──────────────────────────────────────────────


async def test_agent_queries_recent_and_similar_memories():
    agent = _make_agent()
    await agent.run("health_loop_escalation")

    agent.memory.recall_recent.assert_called_once()
    agent.memory.recall_similar.assert_called_once()


# ── Exception handling ──────────────────────────────────────────────


async def test_agent_handles_unhandled_exception():
    agent = _make_agent()
    agent.knowledge.git_pull = AsyncMock(side_effect=Exception("git broken"))

    result = await agent.run("test")

    assert result.outcome == "failed"
    assert not result.success


# ── Structured response parsing ────────────────────────────────────


def test_parse_structured_response_both_tags():
    from maude.healing.room_agent import RoomAgent

    content = (
        "I checked the service and it's healthy.\n"
        "<summary>Service healthy, no issues found</summary>\n"
        "<outcome>no_action</outcome>"
    )
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Service healthy, no issues found"
    assert outcome == "no_action"


def test_parse_structured_response_missing_tags():
    from maude.healing.room_agent import RoomAgent

    content = "Just some text without tags."
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == ""
    assert outcome == ""


def test_parse_structured_response_invalid_outcome():
    from maude.healing.room_agent import RoomAgent

    content = "<summary>Did stuff</summary>\n<outcome>maybe</outcome>"
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Did stuff"
    assert outcome == ""  # "maybe" is not a valid outcome


def test_parse_structured_response_multiline_summary():
    from maude.healing.room_agent import RoomAgent

    content = "<summary>Line one.\nLine two.</summary>\n<outcome>resolved</outcome>"
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert "Line one" in summary
    assert "Line two" in summary
    assert outcome == "resolved"


# ── Outcome classification with structured tags ─────────────────────


async def test_agent_uses_structured_outcome_tags():
    """Agent response with structured tags overrides default classification."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Checked the service.\n"
                "<summary>Service is healthy, memory at 45%</summary>\n"
                "<outcome>no_action</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    result = await agent.run("scheduled_check")

    assert result.outcome == "no_action"
    assert result.summary == "Service is healthy, memory at 45%"


async def test_agent_resolved_requires_tools():
    """Without structured tags and no tools called, outcome cannot be resolved."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="I fixed everything!",
                tool_calls=[],
                model="test",
                tokens_used=50,
            ),
        ]
    )
    result = await agent.run("some issue")

    # No tools called, no structured tags → no_action (not "resolved")
    assert result.outcome == "no_action"


# ── T4 Escalation ──────────────────────────────────────────────────


async def test_agent_t4_escalation_to_claude():
    """Ollama returns escalated → agent hands off to Claude which resolves."""
    ollama_escalation = LLMResponse(
        content=(
            "I cannot diagnose this further.\n"
            "<summary>Need more capable model</summary>\n"
            "<outcome>escalated</outcome>"
        ),
        tool_calls=[],
        model="llama3.2:1.5b",
        tokens_used=30,
    )
    claude_tool_call = LLMResponse(
        content="Let me check.",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="claude-3-haiku-20240307",
        tokens_used=50,
    )
    claude_resolution = LLMResponse(
        content=(
            "Service restarted successfully.\n"
            "<summary>Restarted grafana-server, now healthy</summary>\n"
            "<outcome>resolved</outcome>"
        ),
        tool_calls=[],
        model="claude-3-haiku-20240307",
        tokens_used=60,
    )

    agent = _make_agent()
    # Ollama responds first via send(), then Claude via send_to_fallback()
    agent.llm.send = AsyncMock(return_value=ollama_escalation)
    agent.llm.can_escalate = True
    agent.llm.send_to_fallback = AsyncMock(side_effect=[claude_tool_call, claude_resolution])

    result = await agent.run("health_loop_escalation", {"reason": "grafana down"})

    assert result.outcome == "resolved"
    assert result.escalated is True
    assert result.model == "claude-3-haiku-20240307"
    assert len(result.actions) == 1
    assert result.iterations == 3  # 1 Ollama + 2 Claude
    # send() called once (Ollama), send_to_fallback() called twice (Claude)
    agent.llm.send.assert_called_once()
    assert agent.llm.send_to_fallback.call_count == 2


async def test_agent_t4_escalation_no_claude_available():
    """Ollama returns escalated but no Claude available → normal escalated outcome."""
    ollama_escalation = LLMResponse(
        content=(
            "Cannot fix this.\n<summary>Needs human help</summary>\n<outcome>escalated</outcome>"
        ),
        tool_calls=[],
        model="llama3.2:1.5b",
        tokens_used=30,
    )

    agent = _make_agent()
    agent.llm.send = AsyncMock(return_value=ollama_escalation)
    agent.llm.can_escalate = False

    result = await agent.run("some_issue")

    assert result.outcome == "escalated"
    assert result.escalated is False
    assert result.summary == "Needs human help"


async def test_agent_t4_escalation_only_once():
    """Even if Claude also returns escalated, don't escalate again."""
    ollama_escalation = LLMResponse(
        content="<summary>Need help</summary>\n<outcome>escalated</outcome>",
        tool_calls=[],
        model="llama3.2:1.5b",
        tokens_used=20,
    )
    claude_also_escalated = LLMResponse(
        content="<summary>I also can't fix this</summary>\n<outcome>escalated</outcome>",
        tool_calls=[],
        model="claude-3-haiku-20240307",
        tokens_used=40,
    )

    agent = _make_agent()
    agent.llm.send = AsyncMock(return_value=ollama_escalation)
    agent.llm.can_escalate = True
    agent.llm.send_to_fallback = AsyncMock(return_value=claude_also_escalated)

    result = await agent.run("hard_problem")

    assert result.outcome == "escalated"
    assert result.escalated is True
    # send_to_fallback called once — second escalated breaks normally
    agent.llm.send_to_fallback.assert_called_once()


async def test_agent_no_escalation_on_normal_run():
    """Normal run without escalation — send_to_fallback never called."""
    agent = _make_agent()
    agent.llm.can_escalate = True
    agent.llm.send_to_fallback = AsyncMock()

    result = await agent.run("schedule check")

    assert result.escalated is False
    agent.llm.send_to_fallback.assert_not_called()


async def test_agent_resolved_with_tools_no_tags():
    """With tools called but no structured tags, default to resolved."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="Fixed it by restarting.",
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    result = await agent.run("health_escalation")

    assert result.outcome == "resolved"


# ── Structured tag regex takes last match ─────────────────────────


def test_parse_structured_response_takes_last_match():
    """When LLM outputs multiple tags, the last one should win."""
    from maude.healing.room_agent import RoomAgent

    content = (
        "First attempt:\n"
        "<summary>Wrong answer</summary>\n"
        "<outcome>failed</outcome>\n"
        "\nActually, let me reconsider:\n"
        "<summary>Service is healthy after restart</summary>\n"
        "<outcome>resolved</outcome>"
    )
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Service is healthy after restart"
    assert outcome == "resolved"


# ── Scheduled check enforcement (only no_action → failed) ────────


async def test_scheduled_check_no_tools_no_action_fails():
    """Scheduled check with no tools and no_action outcome → forced failed."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="Everything seems fine.",
                tool_calls=[],
                model="test",
                tokens_used=50,
            ),
        ]
    )
    result = await agent.run("scheduled_check", {"type": "scheduled"})

    assert result.outcome == "failed"
    assert "No diagnostic tools called" in result.summary


async def test_scheduled_check_no_tools_but_explicit_resolved_not_overridden():
    """Scheduled check with explicit <outcome>resolved</outcome> and 0 tools
    should NOT be forced to failed — the agent made a structured claim."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content=(
                    "I checked via the endpoint detail in the trigger context.\n"
                    "<summary>Healthy based on trigger context</summary>\n"
                    "<outcome>resolved</outcome>"
                ),
                tool_calls=[],
                model="test",
                tokens_used=50,
            ),
        ]
    )
    result = await agent.run("scheduled_check", {"type": "scheduled"})

    # "resolved" via structured tag with 0 tools — preserved, not overridden
    assert result.outcome == "resolved"


# ── Scheduled check iteration cap ─────────────────────────────────


async def test_scheduled_check_escalates_at_default_iterations():
    """Scheduled checks cap at scheduled_max_iterations default (10)."""
    tool_response = LLMResponse(
        content="Checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=10,
    )
    # 10 tool responses = hits the scheduled cap
    agent = _make_agent(llm_responses=[tool_response] * 10)
    result = await agent.run("scheduled_check")

    assert result.outcome == "escalated"
    assert result.iterations == 10
    assert "10" in result.summary


async def test_scheduled_check_custom_iteration_cap():
    """Scheduled check respects configured scheduled_max_iterations."""
    tool_response = LLMResponse(
        content="Checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=10,
    )
    # 6 tool responses with cap of 6
    agent = _make_agent(llm_responses=[tool_response] * 6)
    agent.config.scheduled_max_iterations = 6
    result = await agent.run("scheduled_check")

    assert result.outcome == "escalated"
    assert result.iterations == 6


def test_config_scheduled_max_iterations_default():
    """scheduled_max_iterations defaults to 10."""
    config = RoomAgentConfig()
    assert config.scheduled_max_iterations == 10


def test_config_from_dict_scheduled_max_iterations():
    """from_dict parses scheduled_max_iterations."""
    config = RoomAgentConfig.from_dict({"scheduled_max_iterations": 8})
    assert config.scheduled_max_iterations == 8


def test_config_memory_cache_ttl_from_dict():
    """from_dict parses memory_cache_ttl."""
    config = RoomAgentConfig.from_dict({"memory_cache_ttl": 1800.0})
    assert config.memory_cache_ttl == 1800.0


def test_config_scheduled_tools_default_empty():
    """scheduled_tools defaults to empty list."""
    config = RoomAgentConfig()
    assert config.scheduled_tools == []


def test_config_from_dict_scheduled_tools():
    """from_dict parses scheduled_tools."""
    config = RoomAgentConfig.from_dict(
        {
            "tools": ["service_status", "service_health", "pg_vacuum_status"],
            "scheduled_tools": ["service_health", "service_logs"],
        }
    )
    assert config.scheduled_tools == ["service_health", "service_logs"]
    assert len(config.tools) == 3


async def test_scheduled_check_uses_scheduled_tools():
    """Scheduled check restricts tools to scheduled_tools when configured."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="Let me check.",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=30,
            ),
            LLMResponse(
                content="<summary>Healthy</summary>\n<outcome>resolved</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=40,
            ),
        ]
    )
    agent.config.scheduled_tools = ["service_health"]

    await agent.run("scheduled_check")

    # Verify get_tool_schemas was called with scheduled_tools, not full tools
    call_args = agent.tools.get_tool_schemas.call_args
    assert call_args.kwargs.get("allowed_tools") == ["service_health"]


async def test_scheduled_check_falls_back_to_full_tools():
    """Scheduled check uses full tools list when scheduled_tools is empty."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="Let me check.",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=30,
            ),
            LLMResponse(
                content="<summary>Healthy</summary>\n<outcome>resolved</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=40,
            ),
        ]
    )
    agent.config.scheduled_tools = []  # empty — should fall back

    await agent.run("scheduled_check")

    # Should use the full tools list from config.tools
    call_args = agent.tools.get_tool_schemas.call_args
    assert call_args.kwargs.get("allowed_tools") == ["service_status", "grafana_health"]


# ── Qdrant unavailable signaling in context ───────────────────────


async def test_agent_qdrant_unavailable_shows_in_context():
    """When recall_similar returns None, agent should get a notice in context."""
    agent = _make_agent()
    agent.memory.recall_similar = AsyncMock(return_value=None)

    result = await agent.run("health_loop_escalation")

    # Agent should still complete — Qdrant unavailability is informational
    assert result.outcome in ("no_action", "resolved")
    agent.memory.recall_similar.assert_called_once()


# ── RoomAgentConfig.from_dict with empty data (lines 52-54) ──────


def test_config_from_dict_empty():
    """from_dict with empty dict returns defaults."""
    config = RoomAgentConfig.from_dict({})
    assert config.project == ""
    assert config.max_iterations == 10
    assert config.enabled is False


def test_config_from_dict_none():
    """from_dict with None-like falsy returns defaults."""
    config = RoomAgentConfig.from_dict(None)  # type: ignore[arg-type]
    assert config.project == ""


# ── Outcome no_action when no content and no tools (line 233) ────


async def test_agent_no_content_no_tools_no_action():
    """LLM returns empty content with no tool calls → no_action."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(content="", tool_calls=[], model="test", tokens_used=10),
        ]
    )
    result = await agent.run("some trigger")
    assert result.outcome == "no_action"


# ── _build_recent_context with memories (lines 343, 350-354) ─────


async def test_build_recent_context_with_memories():
    """_build_recent_context returns formatted memory lines."""
    from datetime import datetime

    from maude.memory.store import Memory

    agent = _make_agent()
    m = Memory(
        id=1,
        project="grafana",
        memory_type="incident",
        summary="Restarted grafana-server",
        outcome="resolved",
        created_at=datetime(2026, 2, 1, 10, 30),
    )
    agent.memory.recall_recent = AsyncMock(return_value=[m])
    ctx = await agent._build_recent_context()
    assert "Recent Activity" in ctx
    assert "incident" in ctx
    assert "Restarted grafana-server" in ctx


async def test_build_recent_context_pg_disabled():
    """_build_recent_context returns empty when PG disabled."""
    agent = _make_agent()
    agent.config.memory = {"postgresql": False, "qdrant": True}
    ctx = await agent._build_recent_context()
    assert ctx == ""


# ── _build_similar_context with memories (lines 360, 369-372) ────


async def test_build_similar_context_with_memories():
    """_build_similar_context returns formatted similar memories."""
    from maude.memory.store import Memory

    agent = _make_agent()
    m = Memory(
        id=1,
        project="grafana",
        memory_type="incident",
        summary="Previous restart fixed OOM",
        outcome="resolved",
        score=0.87,
    )
    agent.memory.recall_similar = AsyncMock(return_value=[m])
    ctx = await agent._build_similar_context("grafana OOM")
    assert "Similar Past Situations" in ctx
    assert "0.87" in ctx
    assert "Previous restart" in ctx


async def test_build_similar_context_qdrant_disabled():
    """_build_similar_context returns empty when Qdrant disabled."""
    agent = _make_agent()
    agent.config.memory = {"postgresql": True, "qdrant": False}
    ctx = await agent._build_similar_context("test")
    assert ctx == ""


# ── _compose_system with similar_context (line 383) ──────────────


def test_compose_system_with_similar_context():
    """_compose_system includes similar_context in prompt."""
    agent = _make_agent()
    result = agent._compose_system(
        base_knowledge="# Identity\nI am Room 204.",
        recent_context="## Recent Activity\n- stuff",
        similar_context="## Similar Past Situations\n- old stuff",
    )
    assert "Similar Past Situations" in result
    assert "Recent Activity" in result
    assert "Identity" in result


# ── Event publish + escalation logging (lines 490-499) ───────────


async def test_agent_publishes_event_on_completion():
    """Agent with event publisher calls publish after run."""
    agent = _make_agent()
    publisher = AsyncMock()
    publisher.publish = AsyncMock()
    agent._event_publisher = publisher

    await agent.run("test trigger")

    publisher.publish.assert_called_once()
    call_args = publisher.publish.call_args
    assert call_args[0][0] == "agent_run_completed"


async def test_agent_event_publish_failure_graceful():
    """Event publish failure is non-fatal."""
    agent = _make_agent()
    publisher = AsyncMock()
    publisher.publish = AsyncMock(side_effect=Exception("PG NOTIFY failed"))
    agent._event_publisher = publisher

    # Should not raise
    result = await agent.run("test trigger")
    assert result.success is True


# ── Custom model scheduled checks ────────────────────────────────


async def test_scheduled_check_custom_model_skips_system_prompt():
    """Custom model (e.g., example-agent) uses minimal system prompt for scheduled checks."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="example-agent",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Service is healthy.\n"
                "<summary>All systems operational</summary>\n"
                "<outcome>no_action</outcome>"
            ),
            tool_calls=[],
            model="example-agent",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    # Set the LLM config to use a custom model
    agent.config.llm = {"vllm": {"model": "example-agent"}}

    result = await agent.run("scheduled_check")

    assert result.outcome == "no_action"
    # Verify the system prompt sent to the LLM was minimal (just tool list)
    call_kwargs = agent.llm.send.call_args_list[0]
    system_prompt = call_kwargs[1].get("system", "") if call_kwargs[1] else ""
    assert "Available tools:" in system_prompt
    assert "health-check agent" not in system_prompt  # NOT the full slim prompt


async def test_scheduled_check_base_model_uses_full_prompt():
    """Base model (Qwen/Qwen3-8B) still gets the full slim system prompt."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="Qwen/Qwen3-8B",
            tokens_used=20,
        ),
        LLMResponse(
            content=("<summary>Healthy</summary>\n<outcome>no_action</outcome>"),
            tool_calls=[],
            model="Qwen/Qwen3-8B",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    agent.config.llm = {"vllm": {"model": "Qwen/Qwen3-8B"}}

    result = await agent.run("scheduled_check")

    assert result.outcome == "no_action"
    call_kwargs = agent.llm.send.call_args_list[0]
    system_prompt = call_kwargs[1].get("system", "") if call_kwargs[1] else ""
    assert "health-check agent" in system_prompt  # Full slim prompt


def test_is_custom_model_true():
    """Model ending with -agent is custom."""
    agent = _make_agent()
    agent.config.llm = {"vllm": {"model": "example-agent"}}
    assert agent._is_custom_model() is True


def test_is_custom_model_false():
    """Base model name is not custom."""
    agent = _make_agent()
    agent.config.llm = {"vllm": {"model": "Qwen/Qwen3-8B"}}
    assert agent._is_custom_model() is False


def test_is_custom_model_no_config():
    """No vllm config → not custom."""
    agent = _make_agent()
    agent.config.llm = {}
    assert agent._is_custom_model() is False


# ── Self-healing config ──────────────────────────────────────────


def test_self_healing_config_default():
    """self_healing defaults to empty dict."""
    config = RoomAgentConfig()
    assert config.self_healing == {}


def test_self_healing_config_from_dict():
    """from_dict parses self_healing dict."""
    config = RoomAgentConfig.from_dict(
        {
            "self_healing": {"enabled": True, "verify_after": True},
        }
    )
    assert config.self_healing["enabled"] is True
    assert config.self_healing["verify_after"] is True


def test_self_healing_config_from_dict_absent():
    """from_dict with no self_healing key returns empty dict."""
    config = RoomAgentConfig.from_dict({"name": "test"})
    assert config.self_healing == {}


# ── Self-healing system prompt ───────────────────────────────────


def test_system_prompt_includes_self_healing_when_enabled():
    """When self_healing.enabled is True, system prompt has remediation block."""
    agent = _make_agent()
    agent.config.self_healing = {"enabled": True}
    prompt = agent._compose_system("# Identity", "", "")
    assert "Self-Healing Protocol" in prompt
    assert "DIAGNOSE" in prompt
    assert "VERIFY" in prompt
    assert "remediated" in prompt


def test_system_prompt_always_includes_self_healing():
    """Self-healing is always-on — not gated on config."""
    agent = _make_agent()
    agent.config.self_healing = {"enabled": False}
    prompt = agent._compose_system("# Identity", "", "")
    assert "Self-Healing Protocol" in prompt

    agent2 = _make_agent()
    prompt2 = agent2._compose_system("# Identity", "", "")
    assert "Self-Healing Protocol" in prompt2


def test_system_prompt_always_lists_remediated_outcome():
    """The outcome rules always list remediated as a valid option."""
    agent = _make_agent()
    prompt = agent._compose_system("# Identity", "", "")
    assert "remediated" in prompt


# ── Scheduled prompt modes ─────────────────────────────────────


def test_scheduled_prompt_layer1_issues_mode():
    """When run_reason is layer1_issues, prompt tells LLM to investigate."""
    agent = _make_agent()
    prompt = agent._compose_scheduled_system(["service_health", "service_logs"], "layer1_issues")
    assert "DEEPER ANALYSIS" in prompt
    assert "service_logs" in prompt
    assert "remediated" in prompt
    # Should NOT contain the old "If healthy, Do NOT call more tools" instruction
    assert "Do NOT call more tools" not in prompt


def test_scheduled_prompt_deep_check_mode():
    """When run_reason is deep_check, prompt focuses on proactive scanning."""
    agent = _make_agent()
    prompt = agent._compose_scheduled_system(["service_health", "service_trends"], "deep_check")
    assert "Proactive deep check" in prompt
    assert "service_trends" in prompt
    assert "warning patterns" in prompt


def test_scheduled_prompt_startup_mode():
    """Default/startup mode gives baseline instructions."""
    agent = _make_agent()
    prompt = agent._compose_scheduled_system(["service_health"], "startup")
    assert "Baseline health check" in prompt


def test_scheduled_prompt_empty_run_reason_gives_baseline():
    """Empty run_reason falls through to baseline."""
    agent = _make_agent()
    prompt = agent._compose_scheduled_system(["service_health"], "")
    assert "Baseline health check" in prompt


def test_custom_scheduled_system_layer1_issues():
    """Custom model prompt adapts to layer1_issues."""
    agent = _make_agent()
    prompt = agent._compose_custom_scheduled_system(["service_health"], "layer1_issues")
    assert "Layer 1 detected issues" in prompt


def test_custom_scheduled_system_deep_check():
    """Custom model prompt adapts to deep_check."""
    agent = _make_agent()
    prompt = agent._compose_custom_scheduled_system(["service_health"], "deep_check")
    assert "Proactive deep check" in prompt


# ── Remediated outcome storage ───────────────────────────────────


async def test_remediated_outcome_stored_as_remediation_type():
    """Outcome 'remediated' stores memory_type 'remediation'."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc2", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Restarted service, verified healthy.\n"
                "<summary>Restarted grafana-server, health check passed</summary>\n"
                "<outcome>remediated</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=40,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    agent.config.self_healing = {"enabled": True}
    result = await agent.run("health_loop_escalation")

    assert result.outcome == "remediated"
    assert result.success is True
    call_kwargs = agent.memory.store_memory.call_args[1]
    assert call_kwargs["memory_type"] == "remediation"

    # Tier 1: written to "remediations" category
    agent.knowledge.update_memory.assert_called_once()
    category_arg = agent.knowledge.update_memory.call_args[0][0]
    assert category_arg == "remediations"


async def test_remediated_outcome_publishes_remediation_event():
    """Remediated outcome publishes 'remediation_applied' event."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=("<summary>Fixed it</summary>\n<outcome>remediated</outcome>"),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    publisher = AsyncMock()
    publisher.publish = AsyncMock()
    agent._event_publisher = publisher

    await agent.run("health_loop_escalation")

    publisher.publish.assert_called_once()
    event_type = publisher.publish.call_args[0][0]
    assert event_type == "remediation_applied"


async def test_non_remediated_publishes_normal_event():
    """Non-remediated outcome still publishes 'agent_run_completed'."""
    agent = _make_agent()
    publisher = AsyncMock()
    publisher.publish = AsyncMock()
    agent._event_publisher = publisher

    await agent.run("test trigger")

    event_type = publisher.publish.call_args[0][0]
    assert event_type == "agent_run_completed"


# ── Similar context with remediation memories ────────────────────


async def test_similar_context_shows_fix_details_for_remediations():
    """Remediation memories show FIXED prefix and tool names."""
    from maude.memory.store import Memory

    agent = _make_agent()
    m = Memory(
        id=1,
        project="grafana",
        memory_type="remediation",
        summary="Restarted grafana-server after OOM",
        outcome="remediated",
        actions_taken=[
            {"tool": "service_restart", "arguments": {}},
            {"tool": "service_health", "arguments": {}},
        ],
        score=0.92,
    )
    agent.memory.recall_similar = AsyncMock(return_value=[m])
    ctx = await agent._build_similar_context("grafana OOM")
    assert "FIXED:" in ctx
    assert "service_restart" in ctx
    assert "service_health" in ctx
    assert "0.92" in ctx


async def test_similar_context_regular_memory_unchanged():
    """Non-remediation memories still use the original format."""
    from maude.memory.store import Memory

    agent = _make_agent()
    m = Memory(
        id=1,
        project="grafana",
        memory_type="incident",
        summary="Restarted grafana-server",
        outcome="resolved",
        score=0.85,
    )
    agent.memory.recall_similar = AsyncMock(return_value=[m])
    ctx = await agent._build_similar_context("grafana issue")
    assert "FIXED:" not in ctx
    assert "→ resolved" in ctx


# ── Remediated outcome accepted by structured parser ─────────────


def test_parse_structured_response_remediated_outcome():
    """'remediated' is a valid structured outcome."""
    from maude.healing.room_agent import RoomAgent

    content = "<summary>Fixed and verified</summary>\n<outcome>remediated</outcome>"
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Fixed and verified"
    assert outcome == "remediated"


# ── Enriched Qdrant payload ───────────────────────────────────────


async def test_store_result_enriches_qdrant_payload():
    """embed_and_store receives actions_summary, root_cause, tools_used."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_restart", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Restarted the service after crash.\n"
                "<summary>Restarted grafana after service crash</summary>\n"
                "<outcome>resolved</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    await agent.run("health_loop_escalation")

    # Check that embed_and_store was called with enrichment kwargs
    call_kwargs = agent.memory.embed_and_store.call_args[1]
    assert "actions_summary" in call_kwargs
    assert "root_cause" in call_kwargs
    assert "tools_used" in call_kwargs
    assert "service_restart" in call_kwargs["tools_used"]


# ── _extract_root_cause ──────────────────────────────────────────


def test_extract_root_cause_service_crash():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="Restarted after crash down event")
    assert RoomAgent._extract_root_cause("test", result) == "service_crash"


def test_extract_root_cause_memory():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="OOM killed the process")
    assert RoomAgent._extract_root_cause("test", result) == "memory_exhaustion"


def test_extract_root_cause_disk():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="Disk full, cleared old logs")
    assert RoomAgent._extract_root_cause("test", result) == "disk_pressure"


def test_extract_root_cause_connectivity():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="Connection timeout to upstream")
    assert RoomAgent._extract_root_cause("test", result) == "connectivity"


def test_extract_root_cause_health_loop_trigger():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="Something happened")
    assert RoomAgent._extract_root_cause("health_loop_escalation", result) == "health_check_failure"


def test_extract_root_cause_unclassified():
    from maude.healing.room_agent import AgentResult, RoomAgent

    result = AgentResult(summary="Something happened")
    assert RoomAgent._extract_root_cause("manual_trigger", result) == "unclassified"


# ── Trigger message includes past_fix ────────────────────────────


def test_trigger_message_includes_past_fix():
    agent = _make_agent()
    ctx = {"reason": "service down", "past_fix": "restart fixed it last time"}
    msg = agent._compose_trigger_message("health_loop_escalation", ctx)
    assert "previously fixed" in msg
    assert "restart fixed it last time" in msg


def test_trigger_message_without_past_fix():
    agent = _make_agent()
    ctx = {"reason": "service down"}
    msg = agent._compose_trigger_message("health_loop_escalation", ctx)
    assert "previously fixed" not in msg


# ── Conversation logging for fine-tuning ──────────────────────────


async def test_agent_stores_conversation_in_memory():
    """The full messages list is passed to store_memory as conversation."""
    responses = [
        LLMResponse(
            content="Let me check.",
            tool_calls=[ToolCall(id="tc1", name="service_restart", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Service had issues, restarted.\n"
                "<summary>Restarted service after health failure</summary>\n"
                "<outcome>resolved</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    await agent.run("scheduled_check")

    call_kwargs = agent.memory.store_memory.call_args[1]
    conversation = call_kwargs["conversation"]
    assert conversation is not None
    assert isinstance(conversation, list)
    assert len(conversation) >= 3  # user msg + assistant+tool_calls + tool_result
    # First message is the trigger
    assert conversation[0]["role"] == "user"
    # Second message has tool_calls from the assistant
    assert "tool_calls" in conversation[1]
    assert conversation[1]["tool_calls"][0]["name"] == "service_restart"


async def test_agent_stores_conversation_for_incidents():
    """Incident outcomes with tools are stored with conversation."""
    responses = [
        LLMResponse(
            content="Disk critical, investigating.",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Disk issue resolved after cleanup.\n"
                "<summary>Resolved disk pressure</summary>\n"
                "<outcome>resolved</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    await agent.run("disk_alert", {"type": "alert"})

    call_kwargs = agent.memory.store_memory.call_args[1]
    conversation = call_kwargs["conversation"]
    assert conversation is not None
    assert len(conversation) >= 1
    assert conversation[0]["role"] == "user"


# ── Failed outcome stores to Tier 1 ─────────────────────────────


async def test_failed_outcome_stores_to_tier1():
    """Failed outcomes with actions write to failed_attempts knowledge."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Could not fix the issue.\n"
                "<summary>Failed to resolve datasource error</summary>\n"
                "<outcome>failed</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    result = await agent.run("health_loop_escalation")

    assert result.outcome == "failed"
    # Knowledge updated with failed_attempts category
    agent.knowledge.update_memory.assert_called_once()
    category_arg = agent.knowledge.update_memory.call_args[0][0]
    assert category_arg == "failed_attempts"
    entry_arg = agent.knowledge.update_memory.call_args[0][1]
    assert "FAILED:" in entry_arg
    assert "service_status" in entry_arg


# ── Phase 3B: consult_room ────────────────────────────────────────


async def test_consult_room_returns_formatted_context():
    """consult_room queries target room's memory and returns formatted context."""
    import json

    agent = _make_agent()
    memories = [
        {"summary": "Restarted PG after OOM", "outcome": "resolved"},
        {"summary": "Disk cleanup freed space", "outcome": "remediated"},
    ]
    agent.tools.call = AsyncMock(return_value=json.dumps(memories))

    ctx = await agent.consult_room("postgresql", "service OOM crash")

    assert "Consultation: postgresql" in ctx
    assert "Restarted PG after OOM" in ctx
    assert "Disk cleanup freed space" in ctx
    agent.tools.call.assert_called_once_with(
        "memory_recall_similar",
        project="postgresql",
        query="service OOM crash",
        limit=3,
    )


async def test_consult_room_empty_result():
    """consult_room returns empty string when no memories found."""
    agent = _make_agent()
    agent.tools.call = AsyncMock(return_value="")

    ctx = await agent.consult_room("example-scada", "connection refused")
    assert ctx == ""


async def test_consult_room_handles_exception():
    """consult_room returns empty string on failure (non-fatal)."""
    agent = _make_agent()
    agent.tools.call = AsyncMock(side_effect=Exception("MCP timeout"))

    ctx = await agent.consult_room("grafana", "alert timeout")
    assert ctx == ""


async def test_consult_room_handles_plain_text_result():
    """consult_room handles non-JSON string result gracefully."""
    agent = _make_agent()
    agent.tools.call = AsyncMock(return_value="No similar memories found")

    ctx = await agent.consult_room("redis", "connection pool full")
    assert "Consultation: redis" in ctx
    assert "No similar memories" in ctx


# ── Phase 3A: send_complex on iteration > 3 ──────────────────────


async def test_agent_upgrades_to_complex_after_threshold():
    """After 3 iterations, agent uses send_complex instead of send."""
    # 4 tool-call responses (iterations 0-3) + final text response (iteration 4)
    tool_response = LLMResponse(
        content="Still checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="qwen3:8b",
        tokens_used=10,
    )
    final_response = LLMResponse(
        content="<summary>Fixed after deep analysis</summary>\n<outcome>resolved</outcome>",
        tool_calls=[],
        model="qwen3:14b",
        tokens_used=50,
    )

    agent = _make_agent()
    # First 3 calls via send(), then iteration 3+ via send_complex()
    agent.llm.send = AsyncMock(side_effect=[tool_response, tool_response, tool_response])
    agent.llm.send_complex = AsyncMock(side_effect=[tool_response, final_response])
    agent.llm.can_escalate = False

    result = await agent.run("complex_issue")

    assert result.outcome == "resolved"
    assert agent.llm.send.call_count == 3  # iterations 0, 1, 2
    assert agent.llm.send_complex.call_count == 2  # iterations 3, 4


async def test_scheduled_check_never_uses_send_complex():
    """Scheduled checks don't upgrade to complex even after 3 iterations."""
    tool_response = LLMResponse(
        content="Checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=10,
    )
    final_response = LLMResponse(
        content="<summary>Healthy</summary>\n<outcome>no_action</outcome>",
        tool_calls=[],
        model="test",
        tokens_used=20,
    )

    agent = _make_agent()
    agent.llm.send = AsyncMock(
        side_effect=[tool_response, tool_response, tool_response, tool_response, final_response]
    )
    agent.llm.send_complex = AsyncMock()

    result = await agent.run("scheduled_check")

    assert result.outcome == "no_action"
    # send_complex should never be called for scheduled checks
    agent.llm.send_complex.assert_not_called()


async def test_scheduled_check_passes_tool_choice_required():
    """First iteration of scheduled check sends tool_choice='required'."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="Checking...",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=30,
            ),
            LLMResponse(
                content="<summary>Healthy</summary>\n<outcome>resolved</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=40,
            ),
        ]
    )

    await agent.run("scheduled_check")

    # First send() call should have tool_choice="required"
    first_call = agent.llm.send.call_args_list[0]
    assert first_call.kwargs.get("tool_choice") == "required"

    # Second send() call (iteration 1) should NOT have tool_choice
    if len(agent.llm.send.call_args_list) > 1:
        second_call = agent.llm.send.call_args_list[1]
        assert second_call.kwargs.get("tool_choice") is None


async def test_non_scheduled_does_not_pass_tool_choice():
    """Non-scheduled runs should not set tool_choice."""
    agent = _make_agent()

    await agent.run("health_loop_escalation")

    first_call = agent.llm.send.call_args_list[0]
    assert first_call.kwargs.get("tool_choice") is None


# ── Phase 3E: RAG retrieval on large context ──────────────────────


async def test_agent_uses_rag_when_context_exceeds_threshold():
    """When knowledge exceeds threshold, agent switches to RAG retrieval."""
    agent = _make_agent()
    # Make knowledge exceed the RAG threshold
    large_knowledge = "x" * 15000
    agent.knowledge.load_knowledge = AsyncMock(return_value=large_knowledge)
    agent.knowledge.retrieve_relevant = AsyncMock(
        return_value=[
            {
                "source": "skills/health.md",
                "heading": "Diagnostics",
                "content": "Run health checks first",
                "score": "0.92",
            },
        ]
    )
    # Need identity.md to exist
    from pathlib import Path

    agent.knowledge.knowledge_dir = Path("/tmp/fake_knowledge")

    with (
        patch.object(Path, "exists", return_value=True),
        patch.object(Path, "read_text", return_value="I am Room 204"),
    ):
        result = await agent.run("health issue")

    agent.knowledge.retrieve_relevant.assert_called_once_with(
        "health issue",
        "grafana",
        limit=3,
    )
    assert result.outcome in ("no_action", "resolved")


async def test_agent_uses_full_knowledge_when_under_threshold():
    """When knowledge is under threshold, full loading is used (no RAG)."""
    agent = _make_agent()
    # Small knowledge, under threshold
    agent.knowledge.load_knowledge = AsyncMock(return_value="Short knowledge content")
    agent.knowledge.retrieve_relevant = AsyncMock()

    await agent.run("test trigger")

    # retrieve_relevant should NOT be called
    agent.knowledge.retrieve_relevant.assert_not_called()


async def test_agent_falls_back_when_rag_returns_empty():
    """When RAG returns no chunks, full knowledge is used as-is."""
    agent = _make_agent()
    large_knowledge = "y" * 15000
    agent.knowledge.load_knowledge = AsyncMock(return_value=large_knowledge)
    agent.knowledge.retrieve_relevant = AsyncMock(return_value=[])

    result = await agent.run("test trigger")

    # Should still work with the full knowledge since RAG returned nothing
    assert result.outcome in ("no_action", "resolved", "failed")


# ── Complex iteration threshold constant ──────────────────────────


def test_complex_iteration_threshold():
    """RoomAgent._COMPLEX_ITERATION_THRESHOLD is 3."""
    assert RoomAgent._COMPLEX_ITERATION_THRESHOLD == 3


def test_rag_context_threshold():
    """RoomAgent._RAG_CONTEXT_THRESHOLD is 12000."""
    assert RoomAgent._RAG_CONTEXT_THRESHOLD == 12000


def test_memory_cache_ttl():
    """memory_cache_ttl defaults to 1 hour."""
    config = RoomAgentConfig()
    assert config.memory_cache_ttl == 3600.0


# ── Memory cache for scheduled checks ─────────────────────────────


def test_get_cached_memory_empty():
    """Empty cache returns empty string."""
    agent = _make_agent()
    assert agent._get_cached_memory() == ""


def test_get_cached_memory_warm():
    """Warm cache returns cached content."""
    agent = _make_agent()
    agent._update_memory_cache("## Recent Activity\n- stuff")
    assert "Recent Activity" in agent._get_cached_memory()


def test_get_cached_memory_expired():
    """Expired cache returns empty string."""
    import time

    agent = _make_agent()
    agent._update_memory_cache("cached content")
    # Expire the cache by setting expires to the past
    agent._memory_cache_expires = time.monotonic() - 1
    assert agent._get_cached_memory() == ""


async def test_scheduled_check_uses_cached_memory():
    """Routine scheduled check injects cached memory if warm."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="<summary>Healthy</summary>\n<outcome>no_action</outcome>",
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    # Pre-warm the cache
    agent._update_memory_cache("## Recent Activity\n- prior incident resolved")

    await agent.run("scheduled_check")

    # The system prompt sent to the LLM should include the cached context
    call_kwargs = agent.llm.send.call_args_list[0]
    system_prompt = call_kwargs[1].get("system", "") if call_kwargs[1] else ""
    assert "Recent Activity" in system_prompt
    # Memory.recall_recent should NOT be called (zero I/O)
    agent.memory.recall_recent.assert_not_called()


async def test_scheduled_check_empty_cache_no_memory():
    """Routine scheduled check with empty cache skips memory enrichment."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="<summary>Healthy</summary>\n<outcome>no_action</outcome>",
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    # No cache warm-up — cache is empty

    await agent.run("scheduled_check")

    # No memory queries should happen
    agent.memory.recall_recent.assert_not_called()


async def test_escalation_trigger_forces_fresh_memory():
    """Escalation trigger forces fresh Tier 2 load even on scheduled checks."""
    from datetime import datetime

    from maude.memory.store import Memory

    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content="<summary>Fixed</summary>\n<outcome>resolved</outcome>",
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    mem = Memory(
        id=1,
        project="grafana",
        memory_type="incident",
        summary="Previous restart",
        outcome="resolved",
        created_at=datetime(2026, 2, 1, 10, 30),
    )
    agent.memory.recall_recent = AsyncMock(return_value=[mem])

    # Use an escalation trigger that still matches is_scheduled via startswith
    # The trigger contains "escalation" which triggers fresh load
    await agent.run("health_loop_escalation:grafana_down")

    # This is NOT a scheduled_check (trigger != "scheduled_check"), so it goes
    # through the non-scheduled branch which always does full memory enrichment
    agent.memory.recall_recent.assert_called_once()


async def test_interactive_run_invalidates_cache_after_persist():
    """Interactive run invalidates cache after persisting (stale after new data)."""
    agent = _make_agent()
    # Pre-warm the cache
    agent._update_memory_cache("## old context")

    await agent.run("health_loop_escalation")

    # After the run, cache should be invalidated — _persist_memory clears it
    # so the next scheduled check fetches fresh context
    assert agent._memory_cache == ""
    assert agent._memory_cache_expires == 0.0


async def test_cache_ttl_expiry_forces_stale():
    """After TTL expires, cached memory is no longer used."""
    import time

    agent = _make_agent()
    agent._update_memory_cache("## Recent Activity\n- old data")
    # Expire it
    agent._memory_cache_expires = time.monotonic() - 1.0

    assert agent._get_cached_memory() == ""


# ── Strip think tags ─────────────────────────────────────────────


def test_strip_think_tags_closed():
    """Closed <think> blocks are stripped."""
    from maude.healing.room_agent import RoomAgent

    text = "<think>internal reasoning</think>Service is healthy."
    assert RoomAgent._strip_think_tags(text) == "Service is healthy."


def test_strip_think_tags_unclosed():
    """Unclosed <think> blocks (truncated response) are stripped."""
    from maude.healing.room_agent import RoomAgent

    text = "<think>\nOkay, let's see. The user triggered a check..."
    assert RoomAgent._strip_think_tags(text) == ""


def test_strip_think_tags_no_tags():
    """Text without <think> tags is returned unchanged."""
    from maude.healing.room_agent import RoomAgent

    text = "Service is healthy with 18% memory."
    assert RoomAgent._strip_think_tags(text) == text


def test_strip_think_tags_mixed():
    """Closed block followed by content is cleaned correctly."""
    from maude.healing.room_agent import RoomAgent

    text = (
        "<think>Let me check the health status...</think>"
        "Example-scada is healthy with 0 recent errors."
    )
    assert RoomAgent._strip_think_tags(text) == "Example-scada is healthy with 0 recent errors."


def test_strip_think_tags_multiline_closed():
    """Multi-line <think> blocks are stripped."""
    from maude.healing.room_agent import RoomAgent

    text = "<think>\nLine 1\nLine 2\nLine 3\n</think>\nSummary: all good."
    assert RoomAgent._strip_think_tags(text) == "Summary: all good."


def test_strip_think_tags_orphaned_close():
    """Orphaned </think> without opening <think> is stripped (truncation case)."""
    from maude.healing.room_agent import RoomAgent

    text = (
        "and <outcome> tags. Let me check.\n"
        "</think>\n\n"
        "<summary>Service is healthy: GPU at 49C.</summary>"
    )
    assert RoomAgent._strip_think_tags(text) == "<summary>Service is healthy: GPU at 49C.</summary>"


def test_strip_think_tags_orphaned_close_no_tags_after():
    """Orphaned </think> with plain text after."""
    from maude.healing.room_agent import RoomAgent

    text = "reasoning tail\n</think>\nService is healthy."
    assert RoomAgent._strip_think_tags(text) == "Service is healthy."


# ── Parse structured response edge cases ────────────────────────


def test_parse_structured_response_unclosed_summary():
    """Unclosed <summary> tag (token budget exhausted) is still extracted."""
    from maude.healing.room_agent import RoomAgent

    content = "<summary>Service is healthy: GPU at 49C, 1 model loaded."
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Service is healthy: GPU at 49C, 1 model loaded."
    assert outcome == ""


def test_parse_structured_response_unclosed_summary_with_outcome():
    """Unclosed <summary> followed by <outcome> splits correctly."""
    from maude.healing.room_agent import RoomAgent

    content = "<summary>All good<outcome>no_action</outcome>"
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "All good"
    assert outcome == "no_action"


# ── Observation tool suffix matching ────────────────────────────


def test_observation_suffix_filters_room_specific_health_tools():
    """Room-specific health tools like sparks_health are treated as observation."""
    _observation_tools = frozenset(
        {
            "service_health",
            "service_status",
            "service_logs",
            "service_errors",
            "service_trends",
            "service_log_patterns",
        }
    )
    _observation_suffixes = ("_health", "_status", "_models")
    actions = [
        {"tool": "sparks_health", "result": "healthy"},
        {"tool": "bulletin_board_health", "result": "ok"},
        {"tool": "gpu_status", "result": "ok"},
        {"tool": "vllm_models", "result": "1 model"},
    ]
    mutating = [
        a
        for a in actions
        if a.get("tool") not in _observation_tools
        and not any((a.get("tool") or "").endswith(s) for s in _observation_suffixes)
    ]
    assert mutating == [], f"Expected no mutating actions, got: {mutating}"


def test_observation_suffix_preserves_actual_mutations():
    """service_restart is correctly treated as a mutating action."""
    _observation_tools = frozenset(
        {
            "service_health",
            "service_status",
            "service_logs",
            "service_errors",
            "service_trends",
            "service_log_patterns",
        }
    )
    _observation_suffixes = ("_health", "_status", "_models")
    actions = [
        {"tool": "service_health", "result": "unhealthy"},
        {"tool": "service_restart", "result": "ok"},
    ]
    mutating = [
        a
        for a in actions
        if a.get("tool") not in _observation_tools
        and not any((a.get("tool") or "").endswith(s) for s in _observation_suffixes)
    ]
    assert len(mutating) == 1
    assert mutating[0]["tool"] == "service_restart"


# ── Scheduled token caps ─────────────────────────────────────────


async def test_scheduled_max_tokens_layer1():
    """Scheduled check with run_reason=layer1_issues uses 2048 max_tokens."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=20,
            ),
            LLMResponse(
                content="<summary>Investigated</summary>\n<outcome>resolved</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=30,
            ),
        ]
    )
    await agent.run("scheduled_check", {"run_reason": "layer1_issues"})

    first_call = agent.llm.send.call_args_list[0]
    assert first_call.kwargs.get("max_tokens") == 2048


async def test_scheduled_max_tokens_deep_check():
    """Scheduled check with run_reason=deep_check uses 1024 max_tokens."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=20,
            ),
            LLMResponse(
                content="<summary>Scanned</summary>\n<outcome>no_action</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=30,
            ),
        ]
    )
    await agent.run("scheduled_check", {"run_reason": "deep_check"})

    first_call = agent.llm.send.call_args_list[0]
    assert first_call.kwargs.get("max_tokens") == 1024


async def test_scheduled_max_tokens_baseline():
    """Scheduled check with no specific run_reason uses 512 max_tokens."""
    agent = _make_agent(
        llm_responses=[
            LLMResponse(
                content="",
                tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
                model="test",
                tokens_used=20,
            ),
            LLMResponse(
                content="<summary>Healthy</summary>\n<outcome>no_action</outcome>",
                tool_calls=[],
                model="test",
                tokens_used=30,
            ),
        ]
    )
    await agent.run("scheduled_check", {"run_reason": "startup"})

    first_call = agent.llm.send.call_args_list[0]
    assert first_call.kwargs.get("max_tokens") == 512


# ── trend_warning memory type ─────────────────────────────────────


async def test_trend_warning_bypasses_noise_filter():
    """trend_warning outcome is stored even on health triggers where noise filter would skip."""
    responses = [
        LLMResponse(
            content="",
            tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
            model="test",
            tokens_used=20,
        ),
        LLMResponse(
            content=(
                "Memory usage has been climbing 2% per day for 30 days.\n"
                "<summary>Memory trending upward, not critical yet</summary>\n"
                "<outcome>trend_warning</outcome>"
            ),
            tool_calls=[],
            model="test",
            tokens_used=30,
        ),
    ]
    agent = _make_agent(llm_responses=responses)
    result = await agent.run("scheduled_check")

    assert result.outcome == "trend_warning"
    assert result.success is True
    # Noise filter bypassed — should be stored
    agent.memory.store_memory.assert_called_once()
    call_kwargs = agent.memory.store_memory.call_args[1]
    assert call_kwargs["memory_type"] == "trend_warning"


def test_parse_structured_response_trend_warning():
    """trend_warning is a valid structured outcome."""
    from maude.healing.room_agent import RoomAgent

    content = (
        "<summary>Disk usage trending up 1% per day</summary>\n<outcome>trend_warning</outcome>"
    )
    summary, outcome = RoomAgent._parse_structured_response(content)
    assert summary == "Disk usage trending up 1% per day"
    assert outcome == "trend_warning"


def test_scheduled_prompt_includes_trend_warning():
    """Scheduled system prompt lists trend_warning as a valid outcome."""
    agent = _make_agent()
    prompt = agent._compose_scheduled_system(["service_health"], "startup")
    assert "trend_warning" in prompt
    assert "developing concern" in prompt


# ── Velocity tracker unit tests ──────────────────────────────────────


def test_velocity_tracker_not_diminishing_under_min_iterations():
    """Velocity tracker does not flag before min_iterations."""
    tracker = _VelocityTracker()
    tracker.record(50)
    tracker.record(50)
    assert not tracker.is_diminishing(threshold=200, min_iterations=3)


def test_velocity_tracker_diminishing_after_low_output():
    """Velocity tracker flags when last 2 iterations are below threshold."""
    tracker = _VelocityTracker()
    tracker.record(500)  # iteration 0 — healthy
    tracker.record(300)  # iteration 1 — healthy
    tracker.record(100)  # iteration 2 — low
    tracker.record(80)  # iteration 3 — low again
    assert tracker.is_diminishing(threshold=200, min_iterations=3)


def test_velocity_tracker_not_diminishing_with_healthy_output():
    """Velocity tracker does not flag when output is above threshold."""
    tracker = _VelocityTracker()
    tracker.record(500)
    tracker.record(400)
    tracker.record(350)
    tracker.record(300)
    assert not tracker.is_diminishing(threshold=200)


def test_velocity_tracker_no_false_positive_on_zero_data():
    """Velocity tracker skips check when no completion token data exists."""
    tracker = _VelocityTracker()
    tracker.record(0)
    tracker.record(0)
    tracker.record(0)
    tracker.record(0)
    assert not tracker.is_diminishing(threshold=200)


def test_velocity_tracker_budget_unlimited():
    """Budget of 0 means unlimited — never triggers."""
    tracker = _VelocityTracker()
    tracker.record(10000)
    assert not tracker.exceeds_budget(0)


def test_velocity_tracker_budget_exceeded():
    """Budget check triggers when cumulative completions exceed cap."""
    tracker = _VelocityTracker()
    tracker.record(3000)
    tracker.record(2000)
    assert tracker.exceeds_budget(4000)  # 5000 > 4000


def test_velocity_tracker_budget_not_exceeded():
    """Budget check does not trigger when under cap."""
    tracker = _VelocityTracker()
    tracker.record(1000)
    tracker.record(1000)
    assert not tracker.exceeds_budget(4000)  # 2000 < 4000


def test_velocity_tracker_handles_mock_values():
    """Velocity tracker coerces non-integer values to 0 (mock safety)."""
    tracker = _VelocityTracker()
    tracker.record("not_an_int")  # type: ignore[arg-type]
    assert tracker.iteration_completions == [0]
    assert tracker.cumulative_completions == 0


# ── Diminishing returns integration test ─────────────────────────────


async def test_agent_stops_on_diminishing_returns():
    """Agent stops early when token velocity drops below threshold."""
    tool_response = LLMResponse(
        content="Checking...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=100,
        completion_tokens=50,  # Low output per iteration
    )
    responses = [tool_response] * 10  # Would run 5 iterations (max)

    config = RoomAgentConfig(
        project="grafana",
        name="grafana",
        max_iterations=10,
        max_tokens=4096,
        velocity_threshold=200,  # 50 < 200 → should flag
        tools=["service_status"],
        memory={"postgresql": True, "qdrant": True},
        enabled=True,
    )

    llm = AsyncMock()
    llm.send = AsyncMock(side_effect=responses)
    llm.can_escalate = False

    tools = AsyncMock()
    tools.get_tool_schemas = AsyncMock(
        return_value=[{"name": "service_status", "description": "Check", "parameters": {}}]
    )
    tools.call = AsyncMock(return_value="active")
    tools.is_read_only = MagicMock(return_value=False)

    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[])
    memory.recall_similar = AsyncMock(return_value=[])
    memory.store_memory = AsyncMock(return_value=1)
    memory.embed_and_store = AsyncMock(return_value=True)

    knowledge = AsyncMock()
    knowledge.load_knowledge = AsyncMock(return_value="Test identity")
    knowledge.retrieve_relevant = AsyncMock(return_value=[])

    agent = RoomAgent(config, llm, tools, memory, knowledge)
    result = await agent.run("test_trigger")

    assert result.outcome == "diminishing_returns"
    assert result.diminishing_returns is True
    # Should stop before max_iterations (10) — at iteration 3 (index 2)
    # because velocity fires after min_iterations=3
    assert result.iterations < 10


async def test_agent_respects_token_budget():
    """Agent stops when cumulative completion tokens exceed budget."""
    tool_response = LLMResponse(
        content="Investigating...",
        tool_calls=[ToolCall(id="tc1", name="service_status", arguments={})],
        model="test",
        tokens_used=2000,
        completion_tokens=1500,  # Large output per iteration
    )
    responses = [tool_response] * 10

    config = RoomAgentConfig(
        project="grafana",
        name="grafana",
        max_iterations=10,
        max_tokens=4096,
        token_budget=3000,  # Should stop after 2 iterations (1500 * 2 = 3000)
        velocity_threshold=200,
        tools=["service_status"],
        memory={"postgresql": True, "qdrant": True},
        enabled=True,
    )

    llm = AsyncMock()
    llm.send = AsyncMock(side_effect=responses)
    llm.can_escalate = False

    tools = AsyncMock()
    tools.get_tool_schemas = AsyncMock(
        return_value=[{"name": "service_status", "description": "Check", "parameters": {}}]
    )
    tools.call = AsyncMock(return_value="active")
    tools.is_read_only = MagicMock(return_value=False)

    memory = AsyncMock()
    memory.recall_recent = AsyncMock(return_value=[])
    memory.recall_similar = AsyncMock(return_value=[])
    memory.store_memory = AsyncMock(return_value=1)
    memory.embed_and_store = AsyncMock(return_value=True)

    knowledge = AsyncMock()
    knowledge.load_knowledge = AsyncMock(return_value="Test identity")
    knowledge.retrieve_relevant = AsyncMock(return_value=[])

    agent = RoomAgent(config, llm, tools, memory, knowledge)
    result = await agent.run("test_trigger")

    assert result.outcome == "diminishing_returns"
    assert result.diminishing_returns is True
    assert result.completion_tokens >= 3000
