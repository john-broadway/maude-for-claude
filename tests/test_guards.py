# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for daemon.guards — safety decorators."""

import asyncio
import json
import time
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.daemon.guards import (
    _rate_limit_locks,
    _rate_limit_state,
    audit_logged,
    rate_limited,
    requires_confirm,
    set_redis_for_rate_limiting,
)
from maude.daemon.kill_switch import KillSwitch
from maude.testing import FakeRedis, reset_rate_limits


@pytest.fixture
def ks(tmp_path, monkeypatch):
    monkeypatch.setattr("maude.daemon.kill_switch.KILL_SWITCH_DIR", tmp_path)
    return KillSwitch(project="test")


# ── requires_confirm ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_requires_confirm_rejects_without_confirm(ks):
    @requires_confirm(ks)
    async def do_thing(confirm: bool = False, reason: str = "") -> str:
        return "done"

    result = await do_thing(confirm=False, reason="test")
    data = json.loads(result)
    assert "error" in data
    assert "confirm=True" in data["error"]


@pytest.mark.asyncio
async def test_requires_confirm_rejects_without_reason(ks):
    @requires_confirm(ks)
    async def do_thing(confirm: bool = False, reason: str = "") -> str:
        return "done"

    result = await do_thing(confirm=True, reason="")
    data = json.loads(result)
    assert "error" in data
    assert "reason" in data["error"]


@pytest.mark.asyncio
async def test_requires_confirm_passes_with_both(ks):
    @requires_confirm(ks)
    async def do_thing(confirm: bool = False, reason: str = "") -> str:
        return "done"

    result = await do_thing(confirm=True, reason="needed")
    assert result == "done"


@pytest.mark.asyncio
async def test_requires_confirm_blocked_by_kill_switch(ks):
    ks.activate("maintenance")

    @requires_confirm(ks)
    async def do_thing(confirm: bool = False, reason: str = "") -> str:
        return "done"

    result = await do_thing(confirm=True, reason="needed")
    data = json.loads(result)
    assert data["kill_switch"] is True


# ── rate_limited ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_rate_limited_blocks_rapid_calls():
    # Clear state for this test
    _rate_limit_state.pop("rapid_fn", None)

    @rate_limited(min_interval_seconds=60.0)
    async def rapid_fn() -> str:
        return "ok"

    first = await rapid_fn()
    assert first == "ok"

    second = await rapid_fn()
    data = json.loads(second)
    assert "Rate limited" in data["error"]


@pytest.mark.asyncio
async def test_rate_limited_allows_after_interval():
    key = "slow_fn"
    _rate_limit_state.pop(key, None)

    @rate_limited(min_interval_seconds=0.05)
    async def slow_fn() -> str:
        return "ok"

    first = await slow_fn()
    assert first == "ok"

    # Wait past the interval
    time.sleep(0.06)

    second = await slow_fn()
    assert second == "ok"


@pytest.mark.asyncio
async def test_rate_limited_concurrent_calls():
    """Concurrent coroutines must not bypass the rate limit."""
    key = "concurrent_fn"
    _rate_limit_state.pop(key, None)
    _rate_limit_locks.pop(key, None)

    call_count = 0

    @rate_limited(min_interval_seconds=60.0)
    async def concurrent_fn() -> str:
        nonlocal call_count
        call_count += 1
        return "ok"

    results = await asyncio.gather(*[concurrent_fn() for _ in range(5)])

    successes = [r for r in results if r == "ok"]
    rate_limited_responses = [r for r in results if r != "ok"]

    assert len(successes) == 1, f"Expected exactly 1 success, got {len(successes)}"
    assert len(rate_limited_responses) == 4

    for r in rate_limited_responses:
        data = json.loads(r)
        assert "Rate limited" in data["error"]


# ── audit_logged ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_audit_logged_records_call():
    mock_audit = MagicMock()
    mock_audit.log_tool_call = AsyncMock()

    @audit_logged(mock_audit, caller="test-caller")
    async def my_tool(x: int = 1) -> str:
        return "result"

    result = await my_tool(x=42)
    assert result == "result"
    mock_audit.log_tool_call.assert_awaited_once()

    call_kwargs = mock_audit.log_tool_call.call_args[1]
    assert call_kwargs["tool"] == "my_tool"
    assert call_kwargs["caller"] == "test-caller"
    assert call_kwargs["success"] is True


@pytest.mark.asyncio
async def test_audit_logged_records_failure():
    mock_audit = MagicMock()
    mock_audit.log_tool_call = AsyncMock()

    @audit_logged(mock_audit, caller="test")
    async def failing_tool() -> str:
        raise ValueError("boom")

    with pytest.raises(ValueError, match="boom"):
        await failing_tool()

    mock_audit.log_tool_call.assert_awaited_once()
    call_kwargs = mock_audit.log_tool_call.call_args[1]
    assert call_kwargs["success"] is False


# ── Redis-backed rate limiting ────────────────────────────────────


@pytest.mark.asyncio
async def test_rate_limited_with_redis_allows():
    """When Redis is configured, rate_limited uses Redis rate_check."""
    reset_rate_limits()

    fake_redis = FakeRedis()
    set_redis_for_rate_limiting(fake_redis)

    @rate_limited(min_interval_seconds=60.0)
    async def redis_fn() -> str:
        return "ok"

    try:
        result = await redis_fn()
        assert result == "ok"
    finally:
        reset_rate_limits()


@pytest.mark.asyncio
async def test_rate_limited_falls_back_without_redis():
    """Without Redis, rate_limited falls back to in-memory."""
    reset_rate_limits()

    @rate_limited(min_interval_seconds=60.0)
    async def memory_fn() -> str:
        return "ok"

    first = await memory_fn()
    assert first == "ok"

    second = await memory_fn()
    data = json.loads(second)
    assert "Rate limited" in data["error"]

    reset_rate_limits()
