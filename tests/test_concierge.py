# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.concierge — doorman middleware."""

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.middleware.acl import ACLEngine, ACLRule
from maude.middleware.concierge import ConciergeServices, _extract_caller, _prepend_briefing

# ── _prepend_briefing ────────────────────────────────────────────────


def test_prepend_briefing_to_string():
    result = _prepend_briefing("tool output", "Welcome to Room 206")
    assert result.startswith("Welcome to Room 206")
    assert "tool output" in result


def test_prepend_briefing_to_tool_result():
    """Handles FastMCP ToolResult-like objects with .content[].text."""
    item = MagicMock()
    item.text = "original"
    result_obj = MagicMock()
    result_obj.content = [item]

    _prepend_briefing(result_obj, "Briefing")
    assert "Briefing" in item.text
    assert "original" in item.text


def test_prepend_briefing_unknown_type():
    """Unknown types returned unchanged."""
    result = _prepend_briefing(42, "briefing")
    assert result == 42


# ── ConciergeServices ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_tool_call_audited():
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    mw = ConciergeServices(audit=audit, project="test")

    # Mock context
    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {"lines": 50}

    # Mock call_next
    call_next = AsyncMock(return_value="ok")

    result = await mw.on_call_tool(context, call_next)
    assert result == "ok"
    audit.log_tool_call.assert_awaited_once()

    kwargs = audit.log_tool_call.call_args[1]
    assert kwargs["tool"] == "service_status"
    assert kwargs["caller"] == "anonymous"  # No ASGI scope in tests → fallback
    assert kwargs["success"] is True


@pytest.mark.asyncio
async def test_briefing_prepended_on_first_call():
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    guest_book = AsyncMock()
    guest_book.record_call = AsyncMock()
    guest_book.get_briefing = AsyncMock(return_value="Room 206 briefing")

    mw = ConciergeServices(audit=audit, project="test", guest_book=guest_book)

    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {}

    call_next = AsyncMock(return_value="status ok")

    result = await mw.on_call_tool(context, call_next)
    assert "Room 206 briefing" in result
    assert "status ok" in result


@pytest.mark.asyncio
async def test_briefing_cleared_after_first_call():
    """After briefing is consumed, subsequent calls don't get it."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    guest_book = AsyncMock()
    guest_book.record_call = AsyncMock()
    # First call returns briefing, second returns empty
    guest_book.get_briefing = AsyncMock(side_effect=["Briefing", ""])

    mw = ConciergeServices(audit=audit, project="test", guest_book=guest_book)

    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {}

    call_next = AsyncMock(return_value="data")

    # First call: briefing
    result1 = await mw.on_call_tool(context, call_next)
    assert "Briefing" in result1

    # Second call: no briefing
    result2 = await mw.on_call_tool(context, call_next)
    assert result2 == "data"


@pytest.mark.asyncio
async def test_middleware_error_nonfatal():
    """Tool errors are re-raised but audit still fires."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    mw = ConciergeServices(audit=audit, project="test")

    context = MagicMock()
    context.message.name = "failing_tool"
    context.message.arguments = {}

    call_next = AsyncMock(side_effect=RuntimeError("tool broke"))

    with pytest.raises(RuntimeError, match="tool broke"):
        await mw.on_call_tool(context, call_next)

    # Audit should still have been called with success=False
    audit.log_tool_call.assert_awaited()
    kwargs = audit.log_tool_call.call_args[1]
    assert kwargs["success"] is False


# ── Coverage: audit write failure (success path) ─────────────────


@pytest.mark.asyncio
async def test_on_call_tool_audit_failure_nonfatal():
    """Audit failure in the success path is non-fatal; tool result still returned."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock(side_effect=RuntimeError("DB down"))

    mw = ConciergeServices(audit=audit, project="test")

    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {}

    call_next = AsyncMock(return_value="status ok")

    result = await mw.on_call_tool(context, call_next)
    assert result == "status ok"
    audit.log_tool_call.assert_awaited_once()


# ── Coverage: guest book briefing prepend logic ──────────────────


@pytest.mark.asyncio
async def test_on_call_tool_guest_book_prepends_briefing():
    """Guest book briefing is prepended to tool result."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    guest_book = AsyncMock()
    guest_book.record_call = AsyncMock()
    guest_book.get_briefing = AsyncMock(return_value="Welcome to Room 206")

    mw = ConciergeServices(audit=audit, project="test", guest_book=guest_book)

    context = MagicMock()
    context.message.name = "service_health"
    context.message.arguments = {}

    call_next = AsyncMock(return_value="healthy")

    result = await mw.on_call_tool(context, call_next)
    assert "Welcome to Room 206" in result
    assert "healthy" in result
    guest_book.record_call.assert_awaited_once()


# ── Coverage: audit write failure in exception path ──────────────


@pytest.mark.asyncio
async def test_on_call_tool_exception_path_audit_failure():
    """Audit failure in exception path is non-fatal; original exception still raised."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock(side_effect=RuntimeError("DB down"))

    mw = ConciergeServices(audit=audit, project="test")

    context = MagicMock()
    context.message.name = "failing_tool"
    context.message.arguments = {}

    call_next = AsyncMock(side_effect=ValueError("tool broke"))

    with pytest.raises(ValueError, match="tool broke"):
        await mw.on_call_tool(context, call_next)

    audit.log_tool_call.assert_awaited_once()


# ── Coverage: guest book write failure in exception path ─────────


@pytest.mark.asyncio
async def test_on_call_tool_exception_path_guest_book_failure():
    """Guest book failure in exception path is non-fatal."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    guest_book = AsyncMock()
    guest_book.record_call = AsyncMock(side_effect=RuntimeError("GB down"))

    mw = ConciergeServices(audit=audit, project="test", guest_book=guest_book)

    context = MagicMock()
    context.message.name = "failing_tool"
    context.message.arguments = {}

    call_next = AsyncMock(side_effect=ValueError("tool broke"))

    with pytest.raises(ValueError, match="tool broke"):
        await mw.on_call_tool(context, call_next)

    guest_book.record_call.assert_awaited_once()


# ── Coverage: _prepend_briefing with unrecognized type ───────────


def test_prepend_briefing_with_unknown_type():
    """Unknown types are returned unchanged (e.g., int, None)."""
    assert _prepend_briefing(None, "briefing") is None
    assert _prepend_briefing(3.14, "briefing") == 3.14
    assert _prepend_briefing([], "briefing") == []


# ── _extract_caller ───────────────────────────────────────────────


def test_extract_caller_with_header():
    """In test env (no ASGI scope), get_http_headers raises → anonymous."""
    result = _extract_caller(MagicMock())
    assert result == "anonymous"


def test_extract_caller_fallback_on_exception():
    """Falls back to 'anonymous' when get_http_headers fails."""
    result = _extract_caller(MagicMock())
    assert result == "anonymous"


# ── ACL integration in ConciergeServices ──────────────────────────


@pytest.mark.asyncio
async def test_acl_deny_returns_error_json():
    """ACL denial returns JSON error and does not call the tool."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    acl = ACLEngine(
        roles={"admin": ["claude-code"]},
        rules=[ACLRule(tools=["service_restart"], roles=["admin"])],
        default_allow=False,
    )
    mw = ConciergeServices(audit=audit, project="test", acl=acl)

    context = MagicMock()
    context.message.name = "service_restart"
    context.message.arguments = {}
    call_next = AsyncMock(return_value="ok")

    # _extract_caller will return "anonymous" in test env (no ASGI scope)
    result = await mw.on_call_tool(context, call_next)

    # Tool should NOT have been called
    call_next.assert_not_awaited()

    # Result should be a ToolResult with JSON error content
    from fastmcp.tools.tool import ToolResult

    assert isinstance(result, ToolResult)
    data = json.loads(result.content[0].text)
    assert data["error"] == "access_denied"
    assert data["role"] == "unknown"
    assert data["tool"] == "service_restart"

    # Audit should record the denial
    audit.log_tool_call.assert_awaited_once()
    kwargs = audit.log_tool_call.call_args[1]
    assert kwargs["access_decision"] == "denied"


@pytest.mark.asyncio
async def test_acl_allow_proceeds_normally():
    """ACL allow lets the tool execute normally."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    # Allow all tools for all callers
    acl = ACLEngine(
        roles={"viewer": ["*"]},
        rules=[ACLRule(tools=["service_status"], roles=["viewer"])],
        default_allow=True,
    )
    mw = ConciergeServices(audit=audit, project="test", acl=acl)

    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {}
    call_next = AsyncMock(return_value="status ok")

    result = await mw.on_call_tool(context, call_next)
    assert result == "status ok"
    call_next.assert_awaited_once()

    kwargs = audit.log_tool_call.call_args[1]
    assert kwargs["access_decision"] == "allowed"
    assert kwargs["caller_role"] == "viewer"


@pytest.mark.asyncio
async def test_no_acl_proceeds_normally():
    """Without ACL, middleware works as before."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    mw = ConciergeServices(audit=audit, project="test")

    context = MagicMock()
    context.message.name = "service_status"
    context.message.arguments = {}
    call_next = AsyncMock(return_value="ok")

    result = await mw.on_call_tool(context, call_next)
    assert result == "ok"

    kwargs = audit.log_tool_call.call_args[1]
    assert kwargs["access_decision"] == "allowed"
    assert kwargs["caller_role"] == ""


@pytest.mark.asyncio
async def test_acl_deny_audit_failure_nonfatal():
    """Audit failure during ACL denial is non-fatal; error JSON still returned."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock(side_effect=RuntimeError("DB down"))

    acl = ACLEngine(
        roles={"admin": ["claude-code"]},
        rules=[ACLRule(tools=["service_restart"], roles=["admin"])],
        default_allow=False,
    )
    mw = ConciergeServices(audit=audit, project="test", acl=acl)

    context = MagicMock()
    context.message.name = "service_restart"
    context.message.arguments = {}
    call_next = AsyncMock(return_value="ok")

    result = await mw.on_call_tool(context, call_next)
    from fastmcp.tools.tool import ToolResult

    assert isinstance(result, ToolResult)
    data = json.loads(result.content[0].text)
    assert data["error"] == "access_denied"
    call_next.assert_not_awaited()


@pytest.mark.asyncio
async def test_acl_default_policy_allow():
    """Unmatched tools fall to default_allow=True."""
    audit = MagicMock()
    audit.log_tool_call = AsyncMock()

    acl = ACLEngine(
        roles={"viewer": ["*"]},
        rules=[ACLRule(tools=["service_restart"], roles=["admin"])],
        default_allow=True,
    )
    mw = ConciergeServices(audit=audit, project="test", acl=acl)

    context = MagicMock()
    context.message.name = "unmatched_tool"
    context.message.arguments = {}
    call_next = AsyncMock(return_value="result")

    result = await mw.on_call_tool(context, call_next)
    assert result == "result"
    call_next.assert_awaited_once()
