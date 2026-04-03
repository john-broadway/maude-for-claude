# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Room Capability Card — A2A-inspired machine-readable capability descriptor.

Each Room publishes a ``room://card`` MCP Resource describing its identity,
capabilities, tools, dependencies, and live health snapshot.

Static parts are computed once at registration time. The tool list is cached
on first read. Health snapshot is refreshed per read (cheap in-memory read).

Usage::

    from maude.daemon.card import register_card_resource
    register_card_resource(mcp, config, deps_info={"depends_on": [...], "depended_by": [...]})

Authors: John Broadway
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-03-14
"""

import logging
import os
from typing import Any

from maude.daemon.config import RoomConfig
from maude.db import format_json

logger = logging.getLogger(__name__)

MAUDE_VERSION = "4.0.0"


def register_card_resource(
    mcp: Any,
    config: RoomConfig,
    *,
    deps_info: dict[str, list[str]] | None = None,
    health_loop_ref: Any | None = None,
) -> None:
    """Register a ``room://card`` MCP resource on the server.

    Args:
        mcp: FastMCP instance.
        config: Room configuration.
        deps_info: Dict with ``depends_on`` and ``depended_by`` lists.
        health_loop_ref: Object with ``_health_loop`` attribute for
            live health snapshots. Optional — card works without it.
    """
    # Static parts computed once
    static: dict[str, Any] = {
        "name": config.project,
        "version": MAUDE_VERSION,
        "ctid": config.ctid,
        "ip": config.ip,
        "mcp_port": config.mcp_port,
        "description": config.description,
        "provider": (
            f"{os.environ.get('MAUDE_ORG_NAME', 'Your Organization')} / Maude v{MAUDE_VERSION}"
        ),
        "capabilities": {
            "health_loop": bool(config.health_loop and config.health_loop.get("enabled")),
            "room_agent": bool(config.room_agent and config.room_agent.get("enabled")),
            "events": bool(config.events and config.events.get("enabled")),
            "memory": True,
            "acl": bool(config.acl and config.acl.get("enabled")),
            "training_loop": bool(config.training_loop and config.training_loop.get("enabled")),
        },
    }

    # Layer and site from raw config
    raw = config.raw or {}
    if "layer" in raw:
        static["layer"] = raw["layer"]
    if "site" in raw:
        static["site"] = raw["site"]

    # Dependencies
    if deps_info:
        static["dependencies"] = deps_info

    # Tool list cache (populated on first read)
    _tool_cache: dict[str, list[dict[str, Any]]] = {}

    @mcp.resource("room://card", description=f"Capability card for {config.project}")
    async def room_card() -> str:
        """Machine-readable capability card (A2A Agent Card concept)."""
        card = dict(static)

        # Cache tool list on first read
        if "tools" not in _tool_cache:
            try:
                tools = await mcp.get_tools()
                _tool_cache["tools"] = [
                    {
                        "name": t.name,
                        "description": (t.description or "")[:120],
                        "guarded": _is_guarded(t),
                    }
                    for t in tools
                ]
            except Exception:
                _tool_cache["tools"] = []

        card["tools"] = _tool_cache["tools"]
        card["tool_count"] = len(_tool_cache["tools"])

        # Live health snapshot (if health loop available)
        hl = getattr(health_loop_ref, "_health_loop", None) if health_loop_ref else None
        if hl and hasattr(hl, "last_status"):
            last = hl.last_status
            if last:
                card["health"] = {
                    "status": "healthy" if last.get("healthy") else "unhealthy",
                    "last_check": last.get("timestamp", ""),
                }

        return format_json(card)

    logger.info("Registered room://card resource for %s", config.project)


_GUARDED_TOOL_PATTERNS = {
    "restart",
    "cleanup",
    "activate",
    "deactivate",
    "deploy",
    "rebuild",
    "trigger",
}


def _is_guarded(tool: Any) -> bool:
    """Heuristic: tool is guarded if its name contains a mutation keyword."""
    name = getattr(tool, "name", "") or ""
    return any(pattern in name for pattern in _GUARDED_TOOL_PATTERNS)
