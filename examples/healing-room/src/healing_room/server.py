# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)
"""Healing Room — Maude Room example demonstrating the self-healing pattern.

This Room monitors a "fake service" represented by a flag file on disk.
When the flag file is absent the service is considered healthy. When it is
present the service is considered crashed.

The health loop (enabled in config.yaml) detects the crashed state on every
cycle and "restarts" the service by removing the flag file. Every detect-and-heal
cycle is stored as an incident memory so the Room builds an operating history.

This is a toy demonstration — real Rooms call ``executor.run("systemctl restart
<service>")`` to restart actual systemd units. The pattern is identical:

    1. domain_checks() returns a health signal
    2. health loop detects the signal
    3. health loop calls executor to apply the fix
    4. incident stored in memory

Self-healing pattern overview:
    ┌───────────────────────────────────────────────────────────────┐
    │  Health Loop (background asyncio task, interval: 30s)         │
    │                                                               │
    │  1. Call domain_checks()  ──► detect fake service state       │
    │  2. If crashed:                                               │
    │       a. Call executor to "restart" (remove flag file)        │
    │       b. Store incident in memory                             │
    │       c. Log WARN with reason                                 │
    │  3. If healthy:                                               │
    │       a. Log DEBUG "all clear"                                │
    │       b. Send Uptime Kuma heartbeat (if configured)           │
    └───────────────────────────────────────────────────────────────┘

Usage:
    python -m healing_room --config config.yaml
"""

import json
import logging
import random
from pathlib import Path

from maude.memory.memory_tools import register_memory_tools
from maude.memory.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import run_room
from fastmcp import FastMCP

logger = logging.getLogger(__name__)

# Flag file path. When this file exists the fake service is "crashed".
# A real Room would check `systemctl is-active <service>` instead.
_CRASH_FLAG = Path("/tmp/healing-room-fake-service-crashed")


def _fake_service_is_crashed() -> bool:
    """Return True if the fake service flag file is present."""
    return _CRASH_FLAG.exists()


def _fake_service_restart() -> None:
    """Simulate a service restart by removing the crash flag."""
    _CRASH_FLAG.unlink(missing_ok=True)
    logger.info("Fake service restarted — crash flag removed.")


def create_server(config: RoomConfig) -> FastMCP:
    """Create the Healing Room MCP server.

    Attaches a domain_checks callback to the returned FastMCP instance. The
    runner detects the ``_maude_domain_checks`` attribute and passes it to
    the HealthLoop, which calls it on every health cycle.
    """
    mcp = FastMCP(name="Healing Room")
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
        ctid=config.raw.get("room_id", 102),
        ip=config.ip,
    )

    register_memory_tools(mcp, audit, config.project)

    # --- Custom tools ---

    @mcp.tool()
    async def crash_fake_service() -> str:
        """Simulate a fake service crash by creating the crash flag file.

        Call this to trigger the self-healing demonstration. The health loop
        will detect the crash on its next cycle (≤30s) and auto-heal.

        Returns:
            JSON with crash flag path and status.
        """
        _CRASH_FLAG.touch()
        logger.warning("Fake service crashed — flag created at %s", _CRASH_FLAG)
        return json.dumps(
            {
                "crashed": True,
                "flag": str(_CRASH_FLAG),
                "message": "Fake service crashed. Health loop will heal within 30s.",
            }
        )

    @mcp.tool()
    async def fake_service_status() -> str:
        """Check the current state of the fake service.

        Returns:
            JSON with service state and crash flag location.
        """
        crashed = _fake_service_is_crashed()
        return json.dumps(
            {
                "fake_service": "crashed" if crashed else "running",
                "flag_exists": crashed,
                "flag_path": str(_CRASH_FLAG),
            }
        )

    # --- Domain checks callback ---
    # The runner passes this to the HealthLoop via the ``_maude_domain_checks``
    # attribute. The HealthLoop calls it every cycle and acts on the result.
    # Return format: {"healthy": bool, "reason": str, "action": str | None}
    # When action == "restart", the health loop will call executor.run(restart_cmd).

    async def domain_checks() -> dict:
        """Check the fake service and attempt auto-healing if crashed.

        This is the self-healing core. In a real Room this function would check
        application-level signals (HTTP /health, queue depth, datasource ping)
        that systemd cannot detect on its own.

        The function performs the heal itself (for demonstration clarity) and
        stores an incident memory so the Room accumulates operational history.
        Returning {"healthy": True} after healing tells the health loop that no
        systemd restart is needed — the fix was already applied here.
        """
        # Randomly crash the fake service 10% of the time to demo auto-healing
        # without manual intervention. Remove this block in real Rooms.
        if random.random() < 0.10 and not _fake_service_is_crashed():
            _CRASH_FLAG.touch()
            logger.warning("Fake service randomly crashed (demo mode).")

        if not _fake_service_is_crashed():
            return {"healthy": True, "reason": "fake service running"}

        logger.warning("Domain check: fake service CRASHED — initiating heal")

        # Apply the fix
        _fake_service_restart()

        # Record the incident in memory
        try:
            from maude.memory.store import MemoryStore

            store = MemoryStore.get_or_create(config.project)
            await store.store_memory(
                project=config.project,
                memory_type="incident",
                summary="Fake service crash detected and auto-healed",
                trigger="domain_checks: crash flag present",
                reasoning="Crash flag present. Removed flag to simulate restart.",
                outcome="resolved",
            )
        except Exception as exc:
            logger.error("Failed to store incident memory: %s", exc)

        # Return healthy=True — we already healed; no systemd restart needed.
        return {"healthy": True, "reason": "fake service restarted by domain_checks"}

    # Attach to the FastMCP instance so the runner can find it.
    mcp._maude_domain_checks = domain_checks  # type: ignore[attr-defined]

    return mcp


def main() -> None:
    """Entry point."""
    run_room(create_server)
