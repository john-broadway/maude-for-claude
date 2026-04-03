# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# {{PROJECT_TITLE}} MCP Server — per-project MCP for CTID {{CTID}}
#          Claude (Anthropic) <noreply@anthropic.com>
"""{{PROJECT_TITLE}} MCP Server — standalone Maude room for CTID {{CTID}}.

Provides health checks, log access, and guarded lifecycle tools
for the {{SERVICE_NAME}} service.

Run:
    python -m {{PROJECT}}_mcp.server          # HTTP on :{{MCP_PORT}}
    python -m {{PROJECT}}_mcp.server --stdio  # stdio for Claude Code
"""

from maude.audit import AuditLogger
from maude.config import RoomConfig
from maude.deploy import register_deploy_tools
from maude.executor import LocalExecutor
from maude.kill_switch import KillSwitch
from maude.memory_tools import register_memory_tools
from maude.ops import register_ops_tools
from maude.relay_tools import register_relay_tools
from maude.resources import register_ops_resources
from maude.runner import run_room  # also registers room://card
from fastmcp import FastMCP

from {{PROJECT}}_mcp.tools.health import register_health_tools


def create_server(config: RoomConfig) -> FastMCP:
    """Create the {{PROJECT_TITLE}} MCP server from config."""
    mcp = FastMCP(
        name="Maude {{PROJECT_TITLE}} MCP",
        instructions=(
            f"MCP server for the {{SERVICE_NAME}} service "
            f"(CTID {config.ctid}, {config.ip}). "
            f"Provides health checks, log access, and guarded lifecycle tools. "
            f"{config.description}"
        ),
    )
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    # 11 standard ops tools
    register_ops_tools(
        mcp, executor, audit, kill_switch,
        config.service_name, config.project,
        ctid=config.ctid, ip=config.ip,
    )

    # 2 MCP resources (status + config)
    register_ops_resources(
        mcp, executor, config.service_name, config.project,
        ctid=config.ctid, ip=config.ip,
        mcp_port=config.mcp_port, config=config,
    )

    # 8 per-room memory tools
    register_memory_tools(mcp, audit, config.project)

    # 3 deploy tools (self_deploy, self_update, deploy_status)
    register_deploy_tools(
        mcp, executor, audit, kill_switch,
        config.project,
        service_name=config.service_name,
    )

    # 4 A2A relay tools (send, accept, update, inbox)
    register_relay_tools(mcp, audit, config.project)

    # Domain tools
    register_health_tools(mcp, executor, audit)

    return mcp


def main() -> None:
    run_room(create_server)


if __name__ == "__main__":
    main()
