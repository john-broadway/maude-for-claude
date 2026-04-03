# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Shared briefing + fleet tools — used by both server.py (stdio) and mcp.py (HTTP).

Extracted to avoid duplication: both the stdio server and the
HTTP server expose the same briefing tools with identical logic.

"""

import json
import os
from collections.abc import Callable
from typing import Any

from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph
from maude.daemon.card import MAUDE_VERSION
from maude.daemon.guards import audit_logged
from maude.db import format_json

ComponentGetter = Callable[[], tuple[CrossRoomMemory, DependencyGraph, BriefingGenerator]]


def register_briefing_tools(
    mcp: Any,
    audit: Any,
    get_components: ComponentGetter,
) -> None:
    """Register the 6 system-wide briefing tools on an MCP server.

    Args:
        mcp: FastMCP instance (server.py) or self.mcp (mcp.py).
        audit: AuditLogger or NullAudit (duck-typed).
        get_components: Callable returning (CrossRoomMemory, DependencyGraph, BriefingGenerator).
    """

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_briefing(scope: str = "site", minutes: int = 60) -> str:
        """Generate a cross-room briefing across Maude Rooms.

        Summarizes room health, incidents, escalations, and dependency risks.

        Args:
            scope: Data source — "site" or "all" for current site (default),
                "room:<name>" for single-room focus, "hotel" for all sites
                aggregated, or "site:<name>" for a specific remote site.
            minutes: Lookback window in minutes. Defaults to 60.

        Returns:
            Formatted briefing text.
        """
        _, _, briefing = get_components()
        return await briefing.generate(scope=scope, minutes=minutes)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_room_status(minutes: int = 60) -> str:
        """Quick room status grid — one line per room.

        Args:
            minutes: Lookback window in minutes. Defaults to 60.

        Returns:
            Formatted room status grid.
        """
        _, _, briefing = get_components()
        return await briefing.room_status(minutes=minutes)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_dependency_graph(room: str = "") -> str:
        """Show the dependency graph for a room or the full hotel.

        Args:
            room: Room name to show dependencies for. Empty for full graph.

        Returns:
            JSON dependency information.
        """
        _, deps, _ = get_components()
        if room:
            result = {
                "room": room,
                "depends_on": deps.depends_on(room),
                "depended_by": deps.depended_by(room),
                "affected_by": deps.affected_by(room),
            }
        else:
            result = deps.to_dict()
        return json.dumps(result, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_recent_incidents(
        minutes: int = 60,
        scope: str = "site",
        site: str = "",
    ) -> str:
        """Get recent incidents across Maude Rooms.

        Returns resolved, failed, and escalated events (excludes routine checks).

        Args:
            minutes: Lookback window in minutes. Defaults to 60.
            scope: "site" for current site (default), "hotel" for all sites.
            site: When scope="hotel", filter to a specific site (e.g. "site-b").
                  Empty returns all sites.

        Returns:
            JSON list of incidents. Cross-site results include a 'site' field.
        """
        memory, _, briefing = get_components()
        if scope == "hotel":
            if briefing.cross_site is None:
                return json.dumps({"error": "Cross-site federation not configured"})
            incidents = await briefing.cross_site.recent_incidents(
                minutes=minutes, site=site or None
            )
            return format_json(incidents)
        incidents = await memory.recent_incidents(minutes=minutes)
        return format_json(incidents)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_ecosystem_map() -> str:
        """Full ecosystem map — infrastructure, rooms, layers, dependencies.

        Returns the complete floor-to-doors topology as JSON: sites, storage,
        PLCs, all rooms with CTID/IP/ports/status, layer groupings, dependency
        graph, and off-limits resources.

        Returns:
            JSON ecosystem map.
        """
        _, deps, _ = get_components()
        return json.dumps(deps.to_ecosystem_dict(), indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_recent_escalations(
        minutes: int = 60,
        scope: str = "site",
        site: str = "",
    ) -> str:
        """Get recent escalations across Maude Rooms.

        Escalations indicate situations that exceeded a Room Agent's capabilities.

        Args:
            minutes: Lookback window in minutes. Defaults to 60.
            scope: "site" for current site (default), "hotel" for all sites.
            site: When scope="hotel", filter to a specific site (e.g. "site-b").
                  Empty returns all sites.

        Returns:
            JSON list of escalations. Cross-site results include a 'site' field.
        """
        memory, _, briefing = get_components()
        if scope == "hotel":
            if briefing.cross_site is None:
                return json.dumps({"error": "Cross-site federation not configured"})
            escalations = await briefing.cross_site.recent_escalations(
                minutes=minutes, site=site or None
            )
            return format_json(escalations)
        escalations = await memory.recent_escalations(minutes=minutes)
        return format_json(escalations)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_site_grid() -> str:
        """Show all sites with room counts and health status.

        Queries each site's PostgreSQL in parallel and returns a grid showing
        active rooms, unhealthy rooms, and escalation counts per site.
        Unreachable sites are shown as unavailable.

        Returns:
            Formatted site health grid text.
        """
        _, _, briefing = get_components()
        if briefing.cross_site is None:
            return "Cross-site federation not configured (CrossSiteMemory unavailable)"

        grid = await briefing.cross_site.site_health_grid()
        lines = ["SITE HEALTH GRID:", ""]
        for site_name in briefing.cross_site.site_names:
            summaries = grid.get(site_name, [])
            if not summaries:
                lines.append(f"  {site_name:<12} UNREACHABLE")
                continue
            total = len(summaries)
            unhealthy = sum(
                1 for s in summaries if s.get("failed", 0) > 0 or s.get("escalated", 0) > 0
            )
            escalated = sum(s.get("escalated", 0) for s in summaries)
            status = "ATTENTION" if unhealthy > 0 else "ok"
            lines.append(
                f"  {site_name:<12} {status:<10} "
                f"rooms={total} unhealthy={unhealthy} escalations={escalated}"
            )
        return "\n".join(lines)

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_capability_cards(site: str = "") -> str:
        """Build capability cards for all Rooms from the dependency graph.

        Cards are built locally from DependencyGraph metadata — no fan-out
        MCP reads to individual rooms.

        Args:
            site: Filter to a specific site (e.g., "site-a"). Empty for all.

        Returns:
            JSON array of capability cards.
        """
        _, deps, _ = get_components()
        cards: list[dict[str, Any]] = []
        for room_key in deps.all_rooms:
            meta = deps._room_meta.get(room_key, {})
            room_site = meta.get("site", "")
            if site and room_site != site:
                continue
            # Extract short name from "site/room" key
            short_name = room_key.split("/", 1)[-1] if "/" in room_key else room_key
            card: dict[str, Any] = {
                "name": short_name,
                "version": MAUDE_VERSION,
                "ctid": meta.get("ctid", 0),
                "ip": meta.get("ip", ""),
                "mcp_port": meta.get("mcp_port", 0),
                "description": meta.get("description", ""),
                "layer": meta.get("layer", ""),
                "site": room_site,
                "provider": (
                    f"{os.environ.get('MAUDE_ORG_NAME', 'Your Organization')}"
                    f" / Maude v{MAUDE_VERSION}"
                ),
                "dependencies": {
                    "depends_on": deps.depends_on(room_key),
                    "depended_by": deps.depended_by(room_key),
                },
            }
            model = deps.model_for(room_key)
            if model:
                card["model"] = model.get("name", "")
            cards.append(card)
        return json.dumps(cards, indent=2)
