# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""MCP Resources for Maude rooms — read-only data exposed via MCP Resources primitive.

Registers 2 per-room resources:
- ``maude://{project}/status`` — live health state, uptime, service status
- ``maude://{project}/config`` — static room config (CTID, IP, port, capabilities)

Usage::

    from maude.daemon.resources import register_ops_resources
    register_ops_resources(mcp, executor, "redis-server", "redis",
                           ctid=1050, ip="localhost", mcp_port=9500, config=config)

Authors: John Broadway
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-03-14
"""

import logging
from typing import Any

from maude.daemon.config import RoomConfig
from maude.daemon.ops import gather_health_data
from maude.db import format_json

logger = logging.getLogger(__name__)


def register_ops_resources(
    mcp: Any,
    executor: Any,
    service_name: str,
    project: str,
    *,
    ctid: int = 0,
    ip: str = "",
    mcp_port: int = 0,
    config: RoomConfig | None = None,
) -> None:
    """Register 2 standard MCP resources on a FastMCP instance.

    Resources registered:
        maude://{project}/status — live health snapshot
        maude://{project}/config — static room configuration

    Args:
        mcp: FastMCP instance to register resources on.
        executor: SSHExecutor or LocalExecutor for running commands.
        service_name: systemd unit name (e.g., "redis-server").
        project: Project identifier (e.g., "redis").
        ctid: Container ID.
        ip: IP address.
        mcp_port: MCP service port.
        config: RoomConfig for richer config resource. Optional.
    """
    status_uri = f"maude://{project}/status"
    config_uri = f"maude://{project}/config"

    @mcp.resource(status_uri, description=f"Live health status for {project}")
    async def room_status() -> str:
        """Live health state: service active, memory, disk, recent errors."""
        data = await gather_health_data(executor, service_name, project, ctid)
        data["ip"] = ip
        data["mcp_port"] = mcp_port
        return format_json(data)

    @mcp.resource(config_uri, description=f"Static configuration for {project}")
    async def room_config() -> str:
        """Static room config: CTID, IP, port, enabled features."""
        cfg: dict[str, Any] = {
            "project": project,
            "service_name": service_name,
            "ctid": ctid,
            "ip": ip,
            "mcp_port": mcp_port,
        }
        if config:
            cfg["description"] = config.description
            cfg["capabilities"] = {
                "health_loop": bool(config.health_loop and config.health_loop.get("enabled")),
                "room_agent": bool(config.room_agent and config.room_agent.get("enabled")),
                "events": bool(config.events and config.events.get("enabled")),
                "memory": True,
                "acl": bool(config.acl and config.acl.get("enabled")),
                "training_loop": bool(
                    config.training_loop and config.training_loop.get("enabled")
                ),
            }
        return format_json(cfg)

    logger.info(
        "Registered 2 MCP resources for %s (%s, %s)",
        project, status_uri, config_uri,
    )
