# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for tool registry — FastMCP bridge for Room Agent."""

import json
from unittest.mock import AsyncMock, MagicMock

from maude.healing.tool_registry import ToolRegistry


def _make_mock_tool(name: str, has_confirm: bool = False) -> MagicMock:
    """Create a mock FastMCP tool."""
    tool = AsyncMock()

    # Parameters schema
    props = {"name": {"type": "string"}}
    if has_confirm:
        props["confirm"] = {"type": "boolean"}
        props["reason"] = {"type": "string"}
    tool.parameters = {"type": "object", "properties": props}

    # MCP tool representation
    mcp_tool = MagicMock()
    mcp_tool.description = f"Description of {name}"
    mcp_tool.inputSchema = tool.parameters
    tool.to_mcp_tool = MagicMock(return_value=mcp_tool)

    # Tool result
    content_item = MagicMock()
    content_item.text = f"Result from {name}"
    result = MagicMock()
    result.content = [content_item]
    tool.run = AsyncMock(return_value=result)

    return tool


def _make_registry(
    tools: dict[str, MagicMock] | None = None,
    kill_switch_active: bool = False,
) -> ToolRegistry:
    """Create a ToolRegistry with mocked FastMCP."""
    mock_tools = (
        tools
        if tools is not None
        else {
            "service_status": _make_mock_tool("service_status"),
            "service_restart": _make_mock_tool("service_restart", has_confirm=True),
        }
    )

    mock_tool_manager = MagicMock()
    mock_tool_manager._tools = mock_tools

    mock_mcp = MagicMock()
    mock_mcp.get_tools = AsyncMock(return_value=mock_tools)
    mock_mcp.get_tool = AsyncMock(side_effect=lambda n: mock_tools.get(n))
    mock_mcp._tool_manager = mock_tool_manager

    mock_audit = AsyncMock()
    mock_audit.log_tool_call = AsyncMock()

    kill_switch = None
    if kill_switch_active:
        kill_switch = MagicMock()
        kill_switch.active = True

    return ToolRegistry(
        mcp=mock_mcp,
        audit=mock_audit,
        project="monitoring",
        kill_switch=kill_switch,
    )


# ── get_tool_schemas ────────────────────────────────────────────────


async def test_get_tool_schemas_returns_all():
    reg = _make_registry()
    schemas = await reg.get_tool_schemas()
    assert len(schemas) == 2
    names = {s["name"] for s in schemas}
    assert names == {"service_status", "service_restart"}


async def test_get_tool_schemas_filters_by_allowed():
    reg = _make_registry()
    schemas = await reg.get_tool_schemas(allowed_tools=["service_status"])
    assert len(schemas) == 1
    assert schemas[0]["name"] == "service_status"


# ── call — read tool ────────────────────────────────────────────────


async def test_call_read_tool():
    reg = _make_registry()
    result = await reg.call("service_status")

    assert "Result from service_status" in result


async def test_call_nonexistent_tool():
    reg = _make_registry()
    result = await reg.call("nonexistent_tool")

    parsed = json.loads(result)
    assert "error" in parsed
    assert "not found" in parsed["error"]


# ── call — write tool ───────────────────────────────────────────────


async def test_call_write_tool_injects_confirm():
    reg = _make_registry()
    result = await reg.call("service_restart")

    assert "Result from service_restart" in result
    # Verify confirm and reason were injected
    tools = await reg.mcp.get_tools()
    restart_tool = tools["service_restart"]
    run_call = restart_tool.run.call_args
    assert run_call[0][0]["confirm"] is True
    assert "Room Agent" in run_call[0][0]["reason"]


async def test_call_write_tool_blocked_by_kill_switch():
    reg = _make_registry(kill_switch_active=True)
    result = await reg.call("service_restart")

    parsed = json.loads(result)
    assert "kill_switch" in parsed
    assert parsed["kill_switch"] is True


# ── list_tool_names ─────────────────────────────────────────────────


def test_list_tool_names():
    reg = _make_registry()
    names = reg.list_tool_names()
    assert set(names) == {"service_status", "service_restart"}


# ── audit logging ───────────────────────────────────────────────────


async def test_call_sets_active_caller_context():
    """ToolRegistry sets active_caller context var for @audit_logged."""
    from maude.memory.audit import active_caller

    reg = _make_registry()
    observed: list[str] = []

    # Capture the context var value during tool.run()
    original_run = reg.mcp.get_tools.return_value["service_status"].run

    async def capturing_run(*args, **kwargs):
        observed.append(active_caller.get())
        return await original_run(*args, **kwargs)

    reg.mcp.get_tools.return_value["service_status"].run = AsyncMock(
        side_effect=capturing_run,
    )
    reg.mcp.get_tool = AsyncMock(
        side_effect=lambda n: reg.mcp.get_tools.return_value.get(n),
    )

    await reg.call("service_status")
    assert observed == ["room-agent:monitoring"]


# ── logging ────────────────────────────────────────────────────────


async def test_get_tool_schemas_logs_warning_on_empty(caplog):
    """Empty tool schemas should produce a warning log."""
    reg = _make_registry(tools={})
    import logging

    with caplog.at_level(logging.WARNING, logger="maude.healing.tool_registry"):
        schemas = await reg.get_tool_schemas()
    assert schemas == []
    assert "0 tools" in caplog.text


async def test_get_tool_schemas_logs_info_on_success(caplog):
    """Non-empty tool schemas should produce an info log with count."""
    reg = _make_registry()
    import logging

    with caplog.at_level(logging.INFO, logger="maude.healing.tool_registry"):
        schemas = await reg.get_tool_schemas()
    assert len(schemas) == 2
    assert "2 tool schemas available" in caplog.text


async def test_call_nonexistent_logs_info(caplog):
    """Calling a nonexistent tool should log at info level."""
    reg = _make_registry()
    import logging

    with caplog.at_level(logging.INFO, logger="maude.healing.tool_registry"):
        await reg.call("nonexistent_tool")
    assert "not found" in caplog.text


# ── Empty/no-text content (line 150) ─────────────────────────────


async def test_call_tool_empty_content():
    """Tool result with empty content list returns empty string."""
    tools = {"empty_tool": _make_mock_tool("empty_tool")}
    # Override to return empty content
    empty_result = MagicMock()
    empty_result.content = []
    tools["empty_tool"].run = AsyncMock(return_value=empty_result)

    reg = _make_registry(tools=tools)
    result = await reg.call("empty_tool")
    assert result == ""


async def test_call_tool_none_content():
    """Tool result with None content returns empty string."""
    tools = {"none_tool": _make_mock_tool("none_tool")}
    none_result = MagicMock()
    none_result.content = None
    tools["none_tool"].run = AsyncMock(return_value=none_result)

    reg = _make_registry(tools=tools)
    result = await reg.call("none_tool")
    assert result == ""


# ── Exception handling in call_tool (lines 154-158) ──────────────


async def test_call_tool_exception(caplog):
    """Tool that raises should return error JSON and log warning."""
    tools = {"bad_tool": _make_mock_tool("bad_tool")}
    tools["bad_tool"].run = AsyncMock(side_effect=RuntimeError("kaboom"))

    reg = _make_registry(tools=tools)
    import logging

    with caplog.at_level(logging.WARNING, logger="maude.healing.tool_registry"):
        result = await reg.call("bad_tool")

    parsed = json.loads(result)
    assert "error" in parsed
    assert "kaboom" in parsed["error"]
    assert "kaboom" in caplog.text


# ── Audit log failure (lines 172-173) ────────────────────────────


async def test_active_caller_reset_after_call():
    """active_caller context var is reset after tool call completes."""
    from maude.memory.audit import active_caller

    reg = _make_registry()
    assert active_caller.get() == ""

    await reg.call("service_status")
    # Context var should be reset after call
    assert active_caller.get() == ""


# ── list_tool_names with no _tools attr (line 181) ───────────────


def test_list_tool_names_no_tools_attr():
    """list_tool_names with no _tools attribute returns empty list."""
    reg = _make_registry()
    del reg.mcp._tool_manager._tools
    names = reg.list_tool_names()
    assert names == []
