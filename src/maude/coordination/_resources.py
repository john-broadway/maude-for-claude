# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Fleet-level MCP Resources for the Coordinator.

Registers 3 fleet-wide resources:
- ``maude://fleet/dependencies`` — dependency graph from dependencies.yaml
- ``maude://fleet/status`` — fleet health grid (all rooms)
- ``maude://fleet/rooms/{room}`` — per-room detail (template resource)

         Claude (Anthropic) <noreply@anthropic.com>
"""

import json
import logging
from typing import Any

from maude.coordination._tools import ComponentGetter

logger = logging.getLogger(__name__)


def register_fleet_resources(
    mcp: Any,
    get_components: ComponentGetter,
) -> None:
    """Register 3 fleet-level MCP resources on the Coordinator server.

    Args:
        mcp: FastMCP instance to register resources on.
        get_components: Callable returning (CrossRoomMemory, DependencyGraph, BriefingGenerator).
    """

    @mcp.resource(
        "maude://fleet/dependencies",
        description="Fleet dependency graph — all rooms and their relationships",
    )
    async def fleet_dependencies() -> str:
        """Full dependency graph from dependencies.yaml."""
        _, deps, _ = get_components()
        return json.dumps(deps.to_dict(), indent=2)

    @mcp.resource(
        "maude://fleet/status",
        description="Fleet health grid — one line per room",
    )
    async def fleet_status() -> str:
        """Fleet health grid via BriefingGenerator."""
        _, _, briefing = get_components()
        return await briefing.room_status(minutes=60)

    @mcp.resource(
        "maude://fleet/rooms/{room}",
        description="Per-room detail from dependency graph",
    )
    async def fleet_room_detail(room: str) -> str:
        """Detail for a single room: dependencies, metadata, model config."""
        _, deps, _ = get_components()
        result: dict[str, Any] = {
            "room": room,
            "depends_on": deps.depends_on(room),
            "depended_by": deps.depended_by(room),
            "affected_by": deps.affected_by(room),
        }
        model = deps.model_for(room)
        if model:
            result["model"] = model
        meta = deps._room_meta.get(room, {})
        if meta:
            result["metadata"] = meta
        return json.dumps(result, indent=2)

    logger.info("Registered 3 fleet MCP resources on Coordinator")
