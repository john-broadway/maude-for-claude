# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)
"""Governed Room — Maude Room example demonstrating governance.

This Room showcases the three safety guard decorators that every mutating tool
in the Maude framework should carry:

    @requires_confirm  — The caller must pass confirm=True and a non-empty reason.
                         Also checks the kill switch before executing.
    @rate_limited      — Prevents calling a mutating tool more than once per
                         configurable window (default: 60s).
    @audit_logged      — Every call (success or failure) is written to the
                         append-only audit trail via AuditLogger.

Decorator order matters and must always be:

    @mcp.tool()           ← outermost (registers with FastMCP)
    @audit_logged(audit)  ← wraps @requires_confirm so audit sees the final outcome
    @requires_confirm(kill_switch)  ← inner guard
    @rate_limited(60.0)   ← innermost (checked after confirmation)
    async def my_tool(...):
        ...

The kill switch is the master override. When active, @requires_confirm blocks
ALL mutating tools regardless of confirm=True. Activate it via the standard
``kill_switch_activate`` ops tool to put the Room into read-only mode.

Governance guard flow:
    Caller ──► @audit_logged ──► @requires_confirm ──► @rate_limited ──► tool body
                  (always logs)     (confirm + reason     (throttle)
                                     + kill switch)

Usage:
    python -m governed_room --config config.yaml
"""

import json
import time

from maude.memory.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import run_room
from fastmcp import FastMCP

# Simulated state for demonstration tools
_action_log: list[dict] = []


def create_server(config: RoomConfig) -> FastMCP:
    """Create the Governed Room MCP server."""
    mcp = FastMCP(name="Governed Room")
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    register_ops_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        config.service_name,
        config.project,
        ctid=config.raw.get("room_id", 103),
        ip=config.ip,
    )

    # --- Governed tools ---

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    async def dangerous_action(
        target: str,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Perform a dangerous mutating action (guarded by @requires_confirm).

        This tool demonstrates the confirm-gate pattern used by all mutating
        operations in the Maude framework. It will:

        1. Refuse if the kill switch is active.
        2. Refuse if confirm is not True.
        3. Refuse if reason is empty.
        4. Record the call in the audit trail regardless of outcome.

        To call successfully:
            dangerous_action(target="x", confirm=True, reason="testing governance demo")

        Args:
            target: Name of the thing to act on (demo only — no real effect).
            confirm: Must be True to proceed.
            reason: Why this action is needed. Required for the audit trail.

        Returns:
            JSON with outcome and timestamp.
        """
        entry = {
            "action": "dangerous_action",
            "target": target,
            "reason": reason,
            "ts": time.time(),
        }
        _action_log.append(entry)
        return json.dumps(
            {
                "status": "executed",
                "target": target,
                "message": f"Dangerous action applied to '{target}'.",
                "log_size": len(_action_log),
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=10.0)
    async def frequent_action(label: str = "ping") -> str:
        """Perform a frequent action that is rate-limited to once per 10 seconds.

        This tool demonstrates @rate_limited, which prevents rapid-fire calls
        that could overwhelm a downstream resource (e.g., a restart endpoint,
        an external API, a PLC write).

        Calling this tool twice within 10 seconds returns a rate-limit error
        with the remaining wait time.

        Args:
            label: A label for the action (demo only).

        Returns:
            JSON with outcome or a rate-limit error.
        """
        entry = {"action": "frequent_action", "label": label, "ts": time.time()}
        _action_log.append(entry)
        return json.dumps(
            {
                "status": "executed",
                "label": label,
                "message": f"Frequent action '{label}' executed.",
                "log_size": len(_action_log),
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def read_action_log(limit: int = 10) -> str:
        """Read the in-memory action log (audit trail demo).

        This read-only tool is decorated with only @audit_logged — no confirm
        guard, no rate limit. Read operations in the Maude framework are
        broadly authorized; only mutating operations need the full guard stack.

        Args:
            limit: Maximum number of log entries to return.

        Returns:
            JSON with recent action log entries.
        """
        entries = _action_log[-limit:]
        return json.dumps(
            {
                "count": len(entries),
                "entries": entries,
            }
        )

    return mcp


def main() -> None:
    """Entry point."""
    run_room(create_server)
