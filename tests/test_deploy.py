# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.deploy — self-deployment tool registration.

Verifies that register_deploy_tools() produces 3 self-deployment tools
and that each tool behaves correctly under success, failure, and guard
conditions.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import json

import pytest

from maude.daemon.deploy import register_deploy_tools
from maude.testing import (
    FakeAudit,
    FakeExecutor,
    FakeKillSwitch,
    FakeMCP,
    FakeSSHResult,
)

# -- Fixtures ----------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset():
    from maude.testing import reset_rate_limits

    reset_rate_limits()
    yield
    reset_rate_limits()


@pytest.fixture
def audit():
    return FakeAudit()


@pytest.fixture
def kill_switch():
    return FakeKillSwitch()


@pytest.fixture
def mcp():
    return FakeMCP()


# -- Tool registration -------------------------------------------------------


def test_register_deploy_tools_count(mcp, audit, kill_switch):
    """register_deploy_tools registers exactly 3 tools."""
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    assert len(mcp.tools) == 3


def test_register_deploy_tools_names(mcp, audit, kill_switch):
    """All 3 expected tool names are registered."""
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    expected = {"deploy_status", "self_deploy", "self_update"}
    assert set(mcp.tools.keys()) == expected


# -- deploy_status -----------------------------------------------------------


async def test_deploy_status_with_git(mcp, audit, kill_switch):
    """deploy_status returns git info when .git exists."""
    executor = FakeExecutor(
        responses={
            "cd /app/postgresql && git log -1": FakeSSHResult(
                stdout="abc1234full abc1234 2026-02-23 10:30:00 -0700 fix: health check timeout"
            ),
            "cd /app/postgresql && git branch": FakeSSHResult(stdout="main"),
            "cd /app/postgresql && git status": FakeSSHResult(stdout=""),
            "cd /app/maude && git log -1": FakeSSHResult(
                stdout="def5678full def5678 2026-02-23 09:00:00 -0700 v3.1.0 release"
            ),
            "cd /app/maude && git branch": FakeSSHResult(stdout="main"),
            "cd /app/maude && git status": FakeSSHResult(stdout=""),
            "pip show maude": FakeSSHResult(stdout="Version: 3.1.0"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["deploy_status"]()
    data = json.loads(result)

    assert data["project"] == "postgresql"
    assert data["project_dir"] == "/app/postgresql"
    assert data["maude_dir"] == "/app/maude"
    assert data["has_git"] is True
    assert data["project_git"]["commit"] == "abc1234"
    assert data["project_git"]["branch"] == "main"
    assert data["project_git"]["dirty"] is False
    assert data["maude_git"]["commit"] == "def5678"
    assert data["maude_git"]["branch"] == "main"
    assert data["maude_version"] == "3.1.0"


async def test_deploy_status_no_git(mcp, audit, kill_switch):
    """deploy_status returns has_git=false when git commands fail."""
    executor = FakeExecutor(
        responses={
            "git log": FakeSSHResult(stderr="not a git repo", exit_code=128),
            "git branch": FakeSSHResult(stderr="not a git repo", exit_code=128),
            "git status": FakeSSHResult(stderr="not a git repo", exit_code=128),
            "pip show maude": FakeSSHResult(stdout="Version: 3.1.0"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["deploy_status"]()
    data = json.loads(result)

    assert data["has_git"] is False
    assert data["project_git"]["commit"] is None
    assert data["maude_git"]["commit"] is None


async def test_deploy_status_dirty_repo(mcp, audit, kill_switch):
    """deploy_status reports dirty=true when there are uncommitted changes."""
    executor = FakeExecutor(
        responses={
            "cd /app/postgresql && git log-1": FakeSSHResult(
                stdout="abc1234full abc1234 2026-02-23 10:30:00 -0700 wip"
            ),
            "cd /app/postgresql && git branch": FakeSSHResult(stdout="main"),
            "cd /app/postgresql && git status --porcelain": FakeSSHResult(
                stdout=" M src/server.py"
            ),
            "cd /app/maude && git log-1": FakeSSHResult(
                stdout="def5678full def5678 2026-02-23 09:00:00 -0700 v3.1.0"
            ),
            "cd /app/maude && git branch": FakeSSHResult(stdout="main"),
            "cd /app/maude && git status --porcelain": FakeSSHResult(stdout=""),
            "pip show maude": FakeSSHResult(stdout="Version: 3.1.0"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["deploy_status"]()
    data = json.loads(result)

    assert data["project_git"]["dirty"] is True


async def test_deploy_status_custom_dirs(mcp, audit, kill_switch):
    """deploy_status uses custom project_dir and maude_dir when provided."""
    executor = FakeExecutor(
        responses={
            "cd /opt/myproject && git log-1": FakeSSHResult(
                stdout="aaa1111full aaa1111 2026-02-23 10:00:00 -0700 init"
            ),
            "cd /opt/myproject && git branch": FakeSSHResult(stdout="dev"),
            "cd /opt/myproject && git status": FakeSSHResult(stdout=""),
            "cd /opt/maude-lib && git log-1": FakeSSHResult(
                stdout="bbb2222full bbb2222 2026-02-23 09:00:00 -0700 lib"
            ),
            "cd /opt/maude-lib && git branch": FakeSSHResult(stdout="main"),
            "cd /opt/maude-lib && git status": FakeSSHResult(stdout=""),
            "pip show maude": FakeSSHResult(stdout="Version: 3.1.0"),
        }
    )
    register_deploy_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        "myproject",
        project_dir="/opt/myproject",
        maude_dir="/opt/maude-lib",
    )
    result = await mcp.tools["deploy_status"]()
    data = json.loads(result)

    assert data["project_dir"] == "/opt/myproject"
    assert data["maude_dir"] == "/opt/maude-lib"


# -- self_deploy -------------------------------------------------------------


async def test_self_deploy_success(mcp, audit, kill_switch):
    """self_deploy succeeds when all steps complete."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Already up to date."),
            "pip install": FakeSSHResult(stdout=""),
            "systemctl restart": FakeSSHResult(stdout=""),
            "systemctl is-active": FakeSSHResult(stdout="active"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=True, reason="deploy latest")
    data = json.loads(result)

    assert data["status"] == "success"
    assert data["action"] == "self_deploy"
    assert data["project"] == "postgresql"
    assert data["reason"] == "deploy latest"
    assert data["git_pull"]["ok"] is True
    assert data["pip_install"]["ok"] is True
    assert data["restart"]["ok"] is True
    assert data["restart"]["active"] is True

    # Verify restart was called
    restart_calls = [c for c in executor.calls if "systemctl restart" in c]
    assert len(restart_calls) == 1


async def test_self_deploy_pip_failure(mcp, audit, kill_switch):
    """self_deploy does NOT restart when pip install fails."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Updating abc..def"),
            "pip install": FakeSSHResult(stderr="ERROR: could not build", exit_code=1),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=True, reason="test pip fail")
    data = json.loads(result)

    assert data["status"] == "failed"
    assert data["pip_install"]["ok"] is False
    # No restart should have been attempted
    assert "restart" not in data
    restart_calls = [c for c in executor.calls if "systemctl restart" in c]
    assert len(restart_calls) == 0


async def test_self_deploy_git_pull_failure(mcp, audit, kill_switch):
    """self_deploy fails early when git pull fails."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stderr="fatal: not a git repo", exit_code=128),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=True, reason="test git fail")
    data = json.loads(result)

    assert data["status"] == "failed"
    assert data["git_pull"]["ok"] is False
    # No pip install or restart should have been attempted
    assert "pip_install" not in data
    assert "restart" not in data


async def test_self_deploy_kill_switch_blocks(mcp, audit):
    """self_deploy is blocked when kill switch is active."""
    ks = FakeKillSwitch(active=True)
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, ks, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=True, reason="test blocked")
    data = json.loads(result)

    assert "error" in data
    assert data.get("kill_switch") is True
    # No commands should have been executed
    assert len(executor.calls) == 0


async def test_self_deploy_rate_limited(mcp, audit, kill_switch):
    """self_deploy is rate limited — second call within 120s is blocked."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Already up to date."),
            "pip install": FakeSSHResult(stdout=""),
            "systemctl restart": FakeSSHResult(stdout=""),
            "systemctl is-active": FakeSSHResult(stdout="active"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")

    # First call succeeds
    result1 = await mcp.tools["self_deploy"](confirm=True, reason="first deploy")
    data1 = json.loads(result1)
    assert data1["status"] == "success"

    # Second call immediately is rate limited
    result2 = await mcp.tools["self_deploy"](confirm=True, reason="second deploy")
    data2 = json.loads(result2)
    assert "error" in data2
    assert "Rate limited" in data2["error"]


async def test_self_deploy_requires_confirm(mcp, audit, kill_switch):
    """self_deploy requires confirm=True."""
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=False, reason="no confirm")
    data = json.loads(result)

    assert "error" in data
    assert "confirm=True" in data["error"]
    assert len(executor.calls) == 0


async def test_self_deploy_requires_reason(mcp, audit, kill_switch):
    """self_deploy requires a non-empty reason."""
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_deploy"](confirm=True, reason="")
    data = json.loads(result)

    assert "error" in data
    assert "reason" in data["error"]
    assert len(executor.calls) == 0


# -- self_update -------------------------------------------------------------


async def test_self_update_success(mcp, audit, kill_switch):
    """self_update succeeds when all steps complete."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Updating abc..def"),
            "pip install": FakeSSHResult(stdout=""),
            "systemctl restart": FakeSSHResult(stdout=""),
            "systemctl is-active": FakeSSHResult(stdout="active"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_update"](confirm=True, reason="maude v3.2.0")
    data = json.loads(result)

    assert "status" in data, f"Missing 'status' in: {data}"
    assert data["status"] == "success"
    assert data["action"] == "self_update"
    assert data["project"] == "postgresql"
    assert data["reason"] == "maude v3.2.0"
    assert data["git_pull"]["ok"] is True
    assert data["pip_install"]["ok"] is True
    assert data["restart"]["ok"] is True
    assert data["restart"]["active"] is True

    # Verify git pull used maude dir
    pull_calls = [c for c in executor.calls if "git pull" in c]
    assert any("/app/maude" in c for c in pull_calls)

    # Verify pip install used maude dir
    pip_calls = [c for c in executor.calls if "pip install" in c]
    assert any("/app/maude" in c for c in pip_calls)


async def test_self_update_pip_failure(mcp, audit, kill_switch):
    """self_update does NOT restart when pip install fails."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Updating abc..def"),
            "pip install": FakeSSHResult(stderr="ERROR: build failed", exit_code=1),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")
    result = await mcp.tools["self_update"](confirm=True, reason="test pip fail")
    data = json.loads(result)

    assert "status" in data, f"Missing 'status' in: {data}"
    assert data["status"] == "failed"
    assert data["pip_install"]["ok"] is False
    # No restart should have been attempted
    assert "restart" not in data
    restart_calls = [c for c in executor.calls if "systemctl restart" in c]
    assert len(restart_calls) == 0


async def test_self_update_kill_switch_blocks(mcp, audit):
    """self_update is blocked when kill switch is active."""
    ks = FakeKillSwitch(active=True)
    executor = FakeExecutor()
    register_deploy_tools(mcp, executor, audit, ks, "postgresql")
    result = await mcp.tools["self_update"](confirm=True, reason="test blocked")
    data = json.loads(result)

    assert "error" in data
    assert data.get("kill_switch") is True
    assert len(executor.calls) == 0


async def test_self_update_rate_limited(mcp, audit, kill_switch):
    """self_update is rate limited — second call within 300s is blocked."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Already up to date."),
            "pip install": FakeSSHResult(stdout=""),
            "systemctl restart": FakeSSHResult(stdout=""),
            "systemctl is-active": FakeSSHResult(stdout="active"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql")

    # First call succeeds
    result1 = await mcp.tools["self_update"](confirm=True, reason="first update")
    data1 = json.loads(result1)
    assert "status" in data1, f"Missing 'status' in: {data1}"
    assert data1["status"] == "success"

    # Second call immediately is rate limited
    result2 = await mcp.tools["self_update"](confirm=True, reason="second update")
    data2 = json.loads(result2)
    assert "error" in data2
    assert "Rate limited" in data2["error"]


async def test_self_update_default_service_name(mcp, audit, kill_switch):
    """self_update uses default service_name maude@{project}."""
    executor = FakeExecutor(
        responses={
            "git pull": FakeSSHResult(stdout="Already up to date."),
            "pip install": FakeSSHResult(stdout=""),
            "systemctl restart": FakeSSHResult(stdout=""),
            "systemctl is-active": FakeSSHResult(stdout="active"),
        }
    )
    register_deploy_tools(mcp, executor, audit, kill_switch, "redis")
    await mcp.tools["self_update"](confirm=True, reason="test default svc")

    restart_calls = [c for c in executor.calls if "systemctl restart" in c]
    assert any("maude@redis" in c for c in restart_calls)
