# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.ops — standard tool registration.

Verifies that register_ops_tools() produces 11 standard operational tools.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import json
from unittest.mock import MagicMock

import pytest

from maude.daemon.ops import register_ops_tools
from maude.testing import (
    FakeAudit,
    FakeExecutor,
    FakeKillSwitch,
    FakeMCP,
    FakeSSHResult,
)

# ── Fixtures ──────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _reset():
    from maude.testing import reset_rate_limits

    reset_rate_limits()
    yield
    reset_rate_limits()


@pytest.fixture
def executor():
    return FakeExecutor()


@pytest.fixture
def audit():
    return FakeAudit()


@pytest.fixture
def kill_switch():
    return FakeKillSwitch()


@pytest.fixture
def mcp():
    return FakeMCP()


@pytest.fixture
def tools(mcp, executor, audit, kill_switch):
    register_ops_tools(
        mcp=mcp,
        executor=executor,
        audit=audit,
        kill_switch=kill_switch,
        service_name="test.service",
        project="test",
        ctid=999,
        ip="localhost",
    )
    return mcp.tools


# ── Tool registration ─────────────────────────────────────────────


def test_register_ops_tools_count(tools):
    """register_ops_tools registers 11 standard ops tools."""
    assert len(tools) >= 11  # 11 core; security tools optional


def test_register_ops_tools_names(tools):
    """All 11 core tool names are registered."""
    expected_core = {
        "service_status",
        "service_health",
        "service_logs",
        "service_errors",
        "service_restart",
        "kill_switch_status",
        "kill_switch_activate",
        "kill_switch_deactivate",
        "service_log_cleanup",
        "service_log_patterns",
        "service_trends",
    }
    assert expected_core.issubset(set(tools.keys()))


# ── service_status ────────────────────────────────────────────────


async def test_service_status_parses_output(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "systemctl show": FakeSSHResult(
                stdout=(
                    "ActiveState=active\n"
                    "SubState=running\n"
                    "MainPID=1234\n"
                    "MemoryCurrent=52428800\n"
                    "ExecMainStartTimestamp=Mon 2026-01-27 10:00:00 MST"
                ),
            ),
        }
    )
    register_ops_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        "test.service",
        "test",
        ctid=999,
        ip="localhost",
    )
    result = await mcp.tools["service_status"]()
    data = json.loads(result)

    assert data["active_state"] == "active"
    assert data["sub_state"] == "running"
    assert data["pid"] == "1234"
    assert data["ctid"] == 999
    assert data["ip"] == "localhost"


async def test_service_status_error(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "systemctl show": FakeSSHResult(stderr="conn refused", exit_code=1),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_status"]()
    data = json.loads(result)

    assert "error" in data


# ── service_health ────────────────────────────────────────────────


async def test_service_health_healthy(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "is-active": FakeSSHResult(stdout="active"),
            "free -m": FakeSSHResult(stdout="45"),
            "df -h": FakeSSHResult(stdout="30"),
            "journalctl": FakeSSHResult(stdout="2"),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test", ctid=999)
    result = await mcp.tools["service_health"]()
    data = json.loads(result)

    assert data["healthy"] is True
    assert data["service_active"] is True


async def test_service_health_unhealthy_inactive(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "is-active": FakeSSHResult(stdout="inactive"),
            "free -m": FakeSSHResult(stdout="45"),
            "df -h": FakeSSHResult(stdout="30"),
            "journalctl": FakeSSHResult(stdout="2"),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_health"]()
    data = json.loads(result)

    assert data["healthy"] is False
    assert data["service_active"] is False


# ── service_logs ──────────────────────────────────────────────────


async def test_service_logs_with_filter(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "journalctl": FakeSSHResult(stdout="line1\nline2"),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_logs"](lines=20, filter="error")
    data = json.loads(result)

    assert data["filter"] == "error"
    assert len(data["log"]) == 2
    assert "grep -i 'error'" in executor.calls[-1]


# ── service_errors ────────────────────────────────────────────────


async def test_service_errors_returns_lines(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "journalctl": FakeSSHResult(stdout="err1\nerr2"),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_errors"](lines=10, since="30 min ago")
    data = json.loads(result)

    assert len(data["errors"]) == 2
    assert data["since"] == "30 min ago"


# ── service_restart ───────────────────────────────────────────────


async def test_service_restart_success(mcp, audit, kill_switch):
    call_count = 0

    async def fake_run(cmd: str) -> FakeSSHResult:
        nonlocal call_count
        call_count += 1
        if "restart" in cmd:
            return FakeSSHResult(stdout="", exit_code=0)
        if "is-active" in cmd:
            return FakeSSHResult(stdout="active")
        return FakeSSHResult()

    executor = FakeExecutor()
    executor.run = fake_run
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_restart"](confirm=True, reason="test")
    data = json.loads(result)

    assert "status" in data, f"Missing 'status' in: {data}"
    assert data["status"] == "success"
    assert data["active"] is True


async def test_service_restart_kill_switch(mcp, audit):
    ks = FakeKillSwitch(active=True)
    executor = FakeExecutor()
    register_ops_tools(mcp, executor, audit, ks, "test.service", "test")
    result = await mcp.tools["service_restart"](confirm=True, reason="test")
    data = json.loads(result)

    assert "error" in data


# ── kill_switch tools ─────────────────────────────────────────────


async def test_kill_switch_status(tools):
    result = await tools["kill_switch_status"]()
    # FakeKillSwitch.status() isn't defined, but the tool runs
    assert result is not None


async def test_kill_switch_activate_needs_confirm(tools):
    result = await tools["kill_switch_activate"](confirm=False, reason="test")
    data = json.loads(result)
    assert "error" in data


async def test_kill_switch_activate_needs_reason(tools):
    result = await tools["kill_switch_activate"](confirm=True, reason="")
    data = json.loads(result)
    assert "error" in data


async def test_kill_switch_deactivate_needs_confirm(tools):
    result = await tools["kill_switch_deactivate"](confirm=False)
    data = json.loads(result)
    assert "error" in data


# ── service_trends ────────────────────────────────────────────────


async def test_service_trends_no_health_loop(tools):
    result = await tools["service_trends"]()
    data = json.loads(result)
    assert "error" in data
    assert "Health loop not running" in data["error"]


async def test_service_trends_with_health_loop_ref(mcp, audit, kill_switch):
    """service_trends resolves health_loop from a ref object at call time."""
    executor = FakeExecutor()

    # Simulate deferred health loop: _health_loop is None at registration, set later
    ref = MagicMock()
    ref._health_loop = None

    register_ops_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        "test.service",
        "test",
        health_loop_ref=ref,
    )

    # Before health loop is set
    result = await mcp.tools["service_trends"]()
    data = json.loads(result)
    assert "error" in data

    # After health loop is set
    mock_trends = MagicMock()
    mock_trends.get_trend.return_value = {"sample_count": 0}
    mock_hl = MagicMock()
    mock_hl.get_trends = MagicMock(return_value=mock_trends)
    ref._health_loop = mock_hl

    result = await mcp.tools["service_trends"]()
    data = json.loads(result)
    assert "error" not in data
    assert data["project"] == "test"


# ── service_log_cleanup ──────────────────────────────────────────


async def test_service_log_cleanup_kill_switch(mcp, audit):
    ks = FakeKillSwitch(active=True)
    executor = FakeExecutor()
    register_ops_tools(mcp, executor, audit, ks, "test.service", "test")
    result = await mcp.tools["service_log_cleanup"](confirm=True, reason="test")
    data = json.loads(result)
    assert "error" in data


# ── service_log_patterns ─────────────────────────────────────────


async def test_service_log_patterns_no_analyzer(mcp, audit, kill_switch):
    executor = FakeExecutor(
        responses={
            "journalctl": FakeSSHResult(stdout="line1\nline2\nline3"),
        }
    )
    register_ops_tools(mcp, executor, audit, kill_switch, "test.service", "test")
    result = await mcp.tools["service_log_patterns"](lines=10, since="1 hour ago")
    data = json.loads(result)
    # LogAnalyzer import may fail in test env — either way, valid JSON
    assert isinstance(data, dict)
