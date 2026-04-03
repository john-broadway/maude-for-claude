# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Control plane tool registration — one call to wire everything.

register_control_tools(mcp, executor, audit, project,
    mcp_endpoints=[("postgresql", "http://db:9030/mcp")],
    coordination_url="http://coordinator:1080/mcp",
)
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from maude.control.audit import register_audit_tools
from maude.control.briefing import register_briefing_tools
from maude.control.health import register_health_tools
from maude.control.session import register_session_tools


def register_control_tools(
    mcp: Any,
    executor: Any,
    audit: Any,
    project: str,
    *,
    database: str = "agent",
    mcp_endpoints: list[tuple[str, str]] | None = None,
    disk_mounts: list[str] | None = None,
    disk_threshold: int = 80,
    memory_threshold: int = 90,
    projects_dir: Path | None = None,
    coordination_url: str = "",
) -> None:
    """Register all control plane tools on an MCP server.

    This gives the human operator fleet-wide visibility:
    - Session persistence (load/save across context windows)
    - Fleet health (disk, memory, processes, MCP reachability)
    - Disk audit (caches, large files, stale venvs)
    - Git status (uncommitted, unpushed across all repos)
    - Fleet briefing (what happened while you were away)

    Args:
        mcp: FastMCP instance.
        executor: LocalExecutor for running commands.
        audit: AuditLogger instance.
        project: Project name for memory scoping.
        database: PostgreSQL database for session memory.
        mcp_endpoints: List of (name, url) for fleet health checks.
        disk_mounts: Mount points to monitor. Defaults to ["/"].
        disk_threshold: Disk usage percent alert threshold.
        memory_threshold: Memory usage percent alert threshold.
        projects_dir: Root directory for audit tools. Defaults to ~/projects.
        coordination_url: URL of the coordination MCP for briefings.
    """
    register_session_tools(mcp, audit, project, database=database)
    register_health_tools(
        mcp,
        executor,
        audit,
        mcp_endpoints=mcp_endpoints,
        disk_mounts=disk_mounts,
        disk_threshold=disk_threshold,
        memory_threshold=memory_threshold,
    )
    register_audit_tools(mcp, executor, audit, projects_dir=projects_dir)
    register_briefing_tools(mcp, audit, coordination_url=coordination_url)
