# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Self-deployment tools for Maude MCP servers.

Every Room can pull its own code from Gitea, update the maude library,
and report deploy status. Replaces the push-based deploy-fleet.sh with
a pull-based federated model where rooms own their update lifecycle.

Usage:
    from maude.daemon.deploy import register_deploy_tools
    register_deploy_tools(mcp, executor, audit, kill_switch, "postgresql",
                          service_name="maude@postgresql")

Authors: John Broadway
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-02-23
"""

import asyncio
import logging
from typing import Any

from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.db import format_json as _format
from maude.memory.audit import AuditLogger

logger = logging.getLogger(__name__)


def register_deploy_tools(
    mcp: Any,
    executor: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    project: str,
    *,
    service_name: str = "",
    project_dir: str = "",
    maude_dir: str = "",
) -> None:
    """Register 3 self-deployment tools on a FastMCP instance.

    Tools registered:
        Read-only: deploy_status
        Guarded:   self_deploy, self_update

    Args:
        mcp: FastMCP instance to register tools on.
        executor: SSHExecutor or LocalExecutor for running commands.
        audit: AuditLogger for audit trail.
        kill_switch: KillSwitch for guarding write operations.
        project: Project identifier (e.g., "postgresql").
        service_name: systemd unit name. Defaults to "maude@{project}".
        project_dir: Project directory. Defaults to "/app/{project}".
        maude_dir: Maude library directory. Defaults to "/app/maude".
    """
    service_name = service_name or f"maude@{project}"
    project_dir = project_dir or f"/app/{project}"
    maude_dir = maude_dir or "/app/maude"
    venv_pip = f"{project_dir}/.venv/bin/pip"

    _register_status_tool(mcp, executor, audit, project, project_dir, maude_dir, venv_pip)
    _register_self_deploy_tool(
        mcp, executor, audit, kill_switch, project, project_dir, venv_pip, service_name
    )
    _register_self_update_tool(
        mcp, executor, audit, kill_switch, project, maude_dir, venv_pip, service_name
    )


def _register_status_tool(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    project: str,
    project_dir: str,
    maude_dir: str,
    venv_pip: str,
) -> None:
    """Register the read-only deploy_status tool."""

    @mcp.tool()
    @audit_logged(audit)
    async def deploy_status() -> str:
        """Get current deployment state for this Room.

        Returns git commit, branch, last update time, pip versions,
        and whether there are uncommitted changes for both the project
        repo and the maude library.

        Returns:
            JSON with deployment status for project and maude.
        """
        result: dict[str, Any] = {
            "project": project,
            "project_dir": project_dir,
            "maude_dir": maude_dir,
        }

        # Project git status
        proj_git = await _git_info(ssh, project_dir)
        result["project_git"] = proj_git

        # Maude git status
        maude_git = await _git_info(ssh, maude_dir)
        result["maude_git"] = maude_git

        # Maude pip version
        pip_result = await ssh.run(f"{venv_pip} show maude 2>/dev/null | grep Version")
        if pip_result.ok and pip_result.stdout.strip():
            version_line = pip_result.stdout.strip()
            # "Version: 3.1.0" -> "3.1.0"
            result["maude_version"] = version_line.split(":", 1)[-1].strip()
        else:
            result["maude_version"] = None

        result["has_git"] = proj_git.get("commit") is not None

        return _format(result)


async def _git_info(ssh: Any, directory: str) -> dict[str, Any]:
    """Gather git info for a directory."""
    info: dict[str, Any] = {}

    # Commit hash, short hash, date, message
    log_result = await ssh.run(f"cd {directory} && git log -1 --format='%H %h %ci %s' 2>/dev/null")
    if log_result.ok and log_result.stdout.strip():
        parts = log_result.stdout.strip().split(" ", 3)
        if len(parts) >= 4:
            info["commit"] = parts[1]  # short hash
            # parts[2] is date, parts[3] starts with time
            # format: "abc123 abc 2026-02-23 10:30:00 -0700 commit message"
            # Re-parse: full_hash short_hash date time tz message
            full_parts = log_result.stdout.strip().split(" ", 5)
            if len(full_parts) >= 5:
                info["last_update"] = f"{full_parts[2]} {full_parts[3]} {full_parts[4]}"
                info["message"] = full_parts[5] if len(full_parts) > 5 else ""
            else:
                info["last_update"] = ""
                info["message"] = parts[3] if len(parts) > 3 else ""
    else:
        info["commit"] = None
        info["last_update"] = None
        info["message"] = None

    # Branch
    branch_result = await ssh.run(f"cd {directory} && git branch --show-current 2>/dev/null")
    if branch_result.ok and branch_result.stdout.strip():
        info["branch"] = branch_result.stdout.strip()
    else:
        info["branch"] = None

    # Dirty check
    dirty_result = await ssh.run(f"cd {directory} && git status --porcelain 2>/dev/null")
    if dirty_result.ok:
        info["dirty"] = len(dirty_result.stdout.strip()) > 0
    else:
        info["dirty"] = None

    return info


def _register_self_deploy_tool(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    project: str,
    project_dir: str,
    venv_pip: str,
    service_name: str,
) -> None:
    """Register the guarded self_deploy tool."""

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=120.0)
    async def self_deploy(confirm: bool = False, reason: str = "") -> str:
        """Pull and deploy this Room's application code from Gitea.

        Pulls latest code, reinstalls the package, and restarts the service.
        GUARDED: requires confirm=True and reason.

        Rate limited to once per 2 minutes. Blocked when kill switch is active.

        Args:
            confirm: Must be True to proceed.
            reason: Explanation for why the deploy is needed.

        Returns:
            JSON with deploy result for each step.
        """
        result: dict[str, Any] = {
            "action": "self_deploy",
            "project": project,
            "reason": reason,
            "status": "success",
        }

        # Step 1: git pull
        pull = await ssh.run(f"cd {project_dir} && git pull --rebase origin main")
        result["git_pull"] = {"ok": pull.ok, "output": pull.stdout or pull.stderr}
        if not pull.ok:
            result["status"] = "failed"
            return _format(result)

        # Step 2: pip install
        pip = await ssh.run(f"{venv_pip} install -e {project_dir} --quiet")
        result["pip_install"] = {"ok": pip.ok, "output": pip.stdout or pip.stderr}
        if not pip.ok:
            result["status"] = "failed"
            return _format(result)

        # Step 3: restart service
        restart = await ssh.run(f"systemctl restart {service_name}")
        if not restart.ok:
            result["restart"] = {"ok": False, "active": False}
            result["status"] = "failed"
            return _format(result)

        # Step 4: wait and verify
        await asyncio.sleep(3)
        check = await ssh.run(f"systemctl is-active {service_name}")
        active = check.ok and check.stdout.strip() == "active"
        result["restart"] = {"ok": restart.ok, "active": active}
        if not active:
            result["status"] = "failed"

        return _format(result)


def _register_self_update_tool(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    project: str,
    maude_dir: str,
    venv_pip: str,
    service_name: str,
) -> None:
    """Register the guarded self_update tool."""

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def self_update(confirm: bool = False, reason: str = "") -> str:
        """Pull and install the latest maude library from Gitea.

        Updates the maude framework itself, then restarts the service.
        GUARDED: requires confirm=True and reason.

        Rate limited to once per 5 minutes. Blocked when kill switch is active.

        Args:
            confirm: Must be True to proceed.
            reason: Explanation for why the update is needed.

        Returns:
            JSON with update result for each step.
        """
        result: dict[str, Any] = {
            "action": "self_update",
            "project": project,
            "reason": reason,
            "status": "success",
        }

        # Step 1: git pull maude
        pull = await ssh.run(f"cd {maude_dir} && git pull --rebase origin main")
        result["git_pull"] = {"ok": pull.ok, "output": pull.stdout or pull.stderr}
        if not pull.ok:
            result["status"] = "failed"
            return _format(result)

        # Step 2: pip install maude
        pip = await ssh.run(f"{venv_pip} install -e {maude_dir} --quiet")
        result["pip_install"] = {"ok": pip.ok, "output": pip.stdout or pip.stderr}
        if not pip.ok:
            result["status"] = "failed"
            return _format(result)

        # Step 3: restart service
        restart = await ssh.run(f"systemctl restart {service_name}")
        if not restart.ok:
            result["restart"] = {"ok": False, "active": False}
            result["status"] = "failed"
            return _format(result)

        # Step 4: wait and verify
        await asyncio.sleep(3)
        check = await ssh.run(f"systemctl is-active {service_name}")
        active = check.ok and check.stdout.strip() == "active"
        result["restart"] = {"ok": restart.ok, "active": active}
        if not active:
            result["status"] = "failed"

        return _format(result)
