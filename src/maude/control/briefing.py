# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Fleet briefing — what happened while you were away.

Pulls a digest from the coordination layer via JSON-RPC,
summarizing recent incidents, escalations, and fleet health.
"""

from __future__ import annotations

import logging
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db.formatting import format_json

logger = logging.getLogger(__name__)


def register_briefing_tools(
    mcp: Any,
    audit: Any,
    *,
    coordination_url: str = "",
) -> None:
    """Register fleet briefing tools.

    Args:
        mcp: FastMCP instance.
        audit: AuditLogger instance.
        coordination_url: URL of the coordination MCP server (e.g. http://host:port/mcp).
    """

    @mcp.tool()
    @audit_logged(audit)
    async def control_briefing() -> str:
        """Pull fleet digest for recent events.

        Queries the coordination MCP for recent incidents, escalations,
        and fleet health. Provides a "what happened while you were away"
        summary.

        Returns:
            JSON with recent events, incidents, and fleet health summary.
        """
        result: dict[str, Any] = {"source": "coordination"}

        if not coordination_url:
            result["status"] = "no_coordination_url"
            result["note"] = "Set coordination_url to enable fleet briefings"
            return format_json(result)

        try:
            import httpx

            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(
                    coordination_url,
                    json={
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": {
                            "name": "coordination_briefing",
                            "arguments": {},
                        },
                        "id": 1,
                    },
                )
                if resp.status_code == 200:
                    data = resp.json()
                    content = data.get("result", {}).get("content", [])
                    if content:
                        text = content[0].get("text", "") if content else ""
                        result["briefing"] = text[:2000]
                        result["status"] = "ok"
                    else:
                        result["status"] = "empty"
                else:
                    result["status"] = f"error:{resp.status_code}"
        except ImportError:
            result["status"] = "httpx_not_installed"
        except Exception as e:
            result["status"] = "error"
            result["error"] = str(e)[:200]

        return format_json(result)
