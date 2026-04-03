# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Coordination — Maude coordination layer.

She knows what everyone's doing. She always does.

Provides system-wide awareness across all Maude Rooms without
breaking Room autonomy. Components:
- stdio server (server.py) — runs on the control plane as Claude Code MCP
- Streamable HTTP server (mcp.py) — runs on Maude Coordinator as maude@maude
- Web dashboard (web/) — FastAPI + HTMX on :8800

If the Coordinator goes down, all 14+ Rooms keep working exactly as before.
"""

from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.cross_site_memory import CrossSiteMemory
from maude.healing.dependencies import DependencyGraph

__all__ = [
    "BriefingGenerator",
    "CrossRoomMemory",
    "CrossSiteMemory",
    "DependencyGraph",
]
