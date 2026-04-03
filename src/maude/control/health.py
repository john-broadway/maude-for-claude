# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Fleet health monitoring — disk, memory, processes, MCP reachability.

Informational only. The control plane observes but never restarts
the services it monitors. That's the Room's job.
"""

from __future__ import annotations

import logging
import shutil
from pathlib import Path
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db.formatting import format_json

logger = logging.getLogger(__name__)


def register_health_tools(
    mcp: Any,
    executor: Any,
    audit: Any,
    *,
    mcp_endpoints: list[tuple[str, str]] | None = None,
    disk_mounts: list[str] | None = None,
    disk_threshold: int = 80,
    memory_threshold: int = 90,
) -> None:
    """Register fleet health monitoring tools.

    Args:
        mcp: FastMCP instance.
        executor: LocalExecutor for running commands.
        audit: AuditLogger instance.
        mcp_endpoints: List of (name, url) tuples for MCP fleet checks.
        disk_mounts: Mount points to check. Defaults to ["/"].
        disk_threshold: Disk usage percent to alert at.
        memory_threshold: Memory usage percent to alert at.
    """
    endpoints = mcp_endpoints or []
    mounts = disk_mounts or ["/"]

    @mcp.tool()
    @audit_logged(audit)
    async def control_health() -> str:
        """Comprehensive health check across disk, memory, processes, and fleet.

        Checks disk usage, memory, process count, and MCP endpoint
        reachability. Informational only.

        Returns:
            JSON with health status across all dimensions.
        """
        result: dict[str, Any] = {"status": "ok", "checks": {}}
        alerts: list[str] = []

        # Disk usage
        for mount in mounts:
            try:
                usage = shutil.disk_usage(mount)
                pct = round(usage.used / usage.total * 100, 1)
                result["checks"][f"disk_{mount}"] = {
                    "percent": pct,
                    "free_gb": round(usage.free / (1024**3), 1),
                }
                if pct > disk_threshold:
                    alerts.append(f"Disk {mount} at {pct}%")
            except OSError:
                result["checks"][f"disk_{mount}"] = {"error": "inaccessible"}

        # Memory usage
        try:
            meminfo = Path("/proc/meminfo").read_text()
            mem = {}
            for line in meminfo.splitlines():
                parts = line.split()
                if parts[0] in ("MemTotal:", "MemAvailable:"):
                    mem[parts[0].rstrip(":")] = int(parts[1])
            if "MemTotal" in mem and "MemAvailable" in mem:
                pct = round((1 - mem["MemAvailable"] / mem["MemTotal"]) * 100, 1)
                result["checks"]["memory"] = {
                    "percent": pct,
                    "available_gb": round(mem["MemAvailable"] / (1024**2), 1),
                }
                if pct > memory_threshold:
                    alerts.append(f"Memory at {pct}%")
        except Exception:
            result["checks"]["memory"] = {"error": "unavailable"}

        # Claude Code process count (informational)
        try:
            r = await executor.run("pgrep -c -f 'claude' || echo 0")
            stdout = r.stdout if hasattr(r, "stdout") else str(r)
            result["checks"]["claude_processes"] = int(stdout.strip())
        except Exception:
            result["checks"]["claude_processes"] = -1

        # MCP fleet reachability
        if endpoints:
            mcp_status: dict[str, str] = {}
            try:
                import httpx

                async with httpx.AsyncClient(timeout=3.0) as client:
                    for name, url in endpoints:
                        try:
                            resp = await client.get(url)
                            mcp_status[name] = (
                                "ok" if resp.status_code < 500 else f"error:{resp.status_code}"
                            )
                        except Exception:
                            mcp_status[name] = "unreachable"
                            alerts.append(f"MCP {name} unreachable")
            except ImportError:
                mcp_status["note"] = "httpx not installed"
            result["checks"]["mcp_fleet"] = mcp_status

        if alerts:
            result["status"] = "warning"
            result["alerts"] = alerts

        return format_json(result)
