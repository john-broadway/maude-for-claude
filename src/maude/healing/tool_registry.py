# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tool registry for Room Agents — bridges FastMCP tools to direct calls.

Introspects the FastMCP instance to extract registered tools, their schemas,
and wraps them for direct invocation by the Room Agent. This avoids going
through the MCP protocol for internal agent calls.

Write tools (those with @requires_confirm) are identified and can be blocked
by the kill switch. All calls are audited with caller="room-agent:{project}".

Usage:
    registry = ToolRegistry(mcp=server.mcp, audit=server.audit, project="my-service")
    schemas = registry.get_tool_schemas(allowed_tools=["service_status", "grafana_health"])
    result = await registry.call("service_status")
    result = await registry.call("service_restart", confirm=True, reason="Memory at 95%")
"""

import json
import logging
from typing import Any

from maude.memory.audit import AuditLogger, active_caller

logger = logging.getLogger(__name__)


class ToolRegistry:
    """Extract and invoke FastMCP tools directly for Room Agent use.

    Args:
        mcp: The FastMCP instance with registered tools.
        audit: AuditLogger for recording tool calls.
        project: Project name for caller attribution.
        kill_switch: Optional KillSwitch to enforce on write tools.
    """

    def __init__(
        self,
        mcp: Any,
        audit: AuditLogger,
        project: str,
        kill_switch: Any = None,
    ) -> None:
        self.mcp = mcp
        self.audit = audit
        self.project = project
        self.kill_switch = kill_switch
        self._caller = f"room-agent:{project}"

    async def get_tool_schemas(
        self,
        allowed_tools: list[str] | None = None,
    ) -> list[dict[str, Any]]:
        """Get tool schemas in a generic format suitable for LLM tool_use.

        Args:
            allowed_tools: If provided, only include these tool names.

        Returns:
            List of tool schema dicts with name, description, parameters.
        """
        all_tools = await self.mcp.get_tools()
        schemas: list[dict[str, Any]] = []

        for name, tool in all_tools.items():
            if allowed_tools and name not in allowed_tools:
                continue

            mcp_tool = tool.to_mcp_tool()
            schemas.append(
                {
                    "name": name,
                    "description": mcp_tool.description or "",
                    "parameters": mcp_tool.inputSchema or {"type": "object", "properties": {}},
                }
            )

        if not schemas:
            logger.warning(
                "ToolRegistry[%s]: get_tool_schemas returned 0 tools (all_tools=%d, allowed=%s)",
                self.project,
                len(all_tools),
                allowed_tools,
            )
        else:
            logger.info("ToolRegistry[%s]: %d tool schemas available", self.project, len(schemas))

        return schemas

    async def call(self, tool_name: str, **kwargs: Any) -> str:
        """Invoke a tool directly and return its string result.

        Kill switch is checked for write tools (those requiring confirm).
        All calls are audited as room-agent:{project}.

        Args:
            tool_name: Name of the tool to call.
            **kwargs: Tool arguments.

        Returns:
            String result from the tool.
        """
        try:
            tool = await self.mcp.get_tool(tool_name)
            if tool is None:
                logger.info("ToolRegistry[%s]: tool '%s' not found", self.project, tool_name)
                return json.dumps({"error": f"Tool '{tool_name}' not found"})

            # Check kill switch for write tools (those that accept 'confirm' param)
            params = tool.parameters or {}
            props = params.get("properties", {})
            is_write = "confirm" in props

            if is_write and self.kill_switch and self.kill_switch.active:
                return json.dumps(
                    {
                        "error": f"Kill switch active — write tool '{tool_name}' blocked",
                        "kill_switch": True,
                    }
                )

            # For write tools called by the agent, inject confirm and reason
            if is_write:
                kwargs.setdefault("confirm", True)
                kwargs.setdefault("reason", f"Room Agent action ({self.project})")

            # Set caller context so @audit_logged picks up the correct identity
            token = active_caller.set(self._caller)
            try:
                tool_result = await tool.run(kwargs)
            finally:
                active_caller.reset(token)

            # Extract text content from ToolResult
            if tool_result.content:
                texts = []
                for item in tool_result.content:
                    if hasattr(item, "text"):
                        texts.append(item.text)
                return "\n".join(texts)

            return ""

        except Exception as e:
            logger.warning("ToolRegistry: %s failed: %s", tool_name, e)
            return json.dumps({"error": str(e)})

    def list_tool_names(self) -> list[str]:
        """Synchronously list available tool names (from cache)."""
        # Access the internal tool store for sync use (async get_tools() preferred)
        tm = getattr(self.mcp, "_tool_manager", None)
        if tm and hasattr(tm, "_tools"):
            return list(tm._tools.keys())
        return []
