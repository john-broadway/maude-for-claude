# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)
"""Hello Room — minimal Maude Room example.

Boots with ZERO infrastructure. No PostgreSQL, no Qdrant, no Redis.
Just a Room with standard ops tools and one custom tool.
"""

from fastmcp import FastMCP

from maude.memory.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import run_room


def create_server(config: RoomConfig) -> FastMCP:
    """Create the Hello Room MCP server."""
    mcp = FastMCP(name=f"Hello {config.project.title()} Room")
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
        ctid=config.raw.get("room_id", 100),
        ip=config.ip,
    )

    @mcp.tool()
    async def hello(name: str = "World") -> str:
        """Say hello from this Room."""
        return f"Hello, {name}! I am the {config.project} Room."

    return mcp


def main() -> None:
    """Entry point."""
    run_room(create_server)
