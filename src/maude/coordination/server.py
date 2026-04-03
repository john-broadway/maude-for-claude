# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Coordination MCP server — stdio server for Claude Code integration.

The concierge. One endpoint for Claude Code with:
- Cross-room briefings, room status, dependency graphs, incidents
- Organizational intelligence (department agents)
- Semantic search (agent knowledge + document vectors)
- ERP search (semantic + structured query over business records)
- Fleet model management

Added to ~/.claude/.mcp.json as a stdio server running on the control plane.

Usage:
    python -m maude.coordination.server
"""

import json
import logging
import os
from pathlib import Path
from typing import Any

from fastmcp import FastMCP

from maude.coordination._governance import register_governance_tools
from maude.coordination._memory_tools import register_memory_tools
from maude.coordination._resources import register_fleet_resources
from maude.coordination._tools import register_briefing_tools
from maude.coordination.agency import register_agency_tools
from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph

try:
    from maude.coordination.erp import register_erp_tools as _register_erp
except ImportError:
    _register_erp = None  # type: ignore[assignment,misc]
from maude.coordination.search import register_search_tools
from maude.daemon.guards import audit_logged

logger = logging.getLogger(__name__)

mcp = FastMCP(
    name="Maude Coordinator",
    instructions=(
        "Maude concierge. One endpoint for system-wide coordination, "
        "organizational intelligence (department agents), semantic search "
        "across all knowledge, fleet management, and cross-room awareness."
    ),
)


# ── Null audit for stdio mode (no PostgreSQL required) ───────────


class _NullAudit:
    """No-op audit logger for stdio mode where PostgreSQL may not be reachable."""

    async def log_tool_call(self, **kwargs: Any) -> None:
        pass


_audit = _NullAudit()


# ── Shared instances (lazy-connected on first tool call) ─────────

_memory: CrossRoomMemory | None = None
_deps: DependencyGraph | None = None
_briefing: BriefingGenerator | None = None


def _get_components() -> tuple[CrossRoomMemory, DependencyGraph, BriefingGenerator]:
    """Lazy-init shared components."""
    global _memory, _deps, _briefing
    if _memory is None:
        _memory = CrossRoomMemory()
    if _deps is None:
        _deps = DependencyGraph()
    if _briefing is None:
        _briefing = BriefingGenerator(_memory, _deps)
    return _memory, _deps, _briefing


# ── Briefing + Dependency tools (shared with mcp.py) ─────────────

register_briefing_tools(mcp, _audit, _get_components)

# ── Fleet resources (read-only MCP Resources primitive) ───────────

register_fleet_resources(mcp, _get_components)


# ── Fleet tools ──────────────────────────────────────────────────


@mcp.tool()
@audit_logged(_audit)  # type: ignore[arg-type]
async def fleet_model_status() -> str:
    """Show which vLLM model each Room uses and whether it's loaded.

    Reads model config from dependencies.yaml and checks vLLM for loaded models.

    Returns:
        JSON with per-room model status.
    """
    from maude.healing.model_manager import VLLMModelManager

    _, deps, _ = _get_components()
    mgr = VLLMModelManager()

    try:
        existing = await mgr.list_models()
        existing_ids = {m.get("id", "") for m in existing}
    except Exception:
        existing_ids = set()

    rooms_status = []
    for room in deps.all_rooms:
        model_cfg = deps.model_for(room)
        if model_cfg:
            name = model_cfg["name"]
            rooms_status.append(
                {
                    "room": room,
                    "model": name,
                    "base": model_cfg.get("base", "Qwen/Qwen3-8B"),
                    "loaded_on_vllm": name in existing_ids,
                }
            )
        else:
            rooms_status.append(
                {
                    "room": room,
                    "model": None,
                    "base": None,
                    "loaded_on_vllm": False,
                }
            )

    await mgr.close()
    return json.dumps({"rooms": rooms_status, "vllm_hosts": mgr._vllm._hosts}, indent=2)


# ── Agency + Search tools ────────────────────────────────────────

# Agency: organizational intelligence from department agent.md files
_agency_root = Path(os.environ.get("AGENCY_ROOT", str(Path.home() / "projects" / "agency")))
register_agency_tools(mcp, _audit, _agency_root)

# Search: semantic search over agent knowledge + document vectors
register_search_tools(mcp, _audit)

# ERP: semantic + structured search over ERP business records
# In stdio mode, config comes from env vars (if set)
_erp_cfg: dict[str, Any] = {}
if os.environ.get("ERPNEXT_API_KEY"):
    _erp_cfg = {
        "host": os.environ.get("ERPNEXT_HOST", ""),
        "port": int(os.environ.get("ERPNEXT_PORT", "8080")),
        "site": os.environ.get("ERPNEXT_SITE", "erp.local"),
        "api_key": os.environ["ERPNEXT_API_KEY"],
        "api_secret": os.environ.get("ERPNEXT_API_SECRET", ""),
    }
if _register_erp is not None:
    _register_erp(mcp, _audit, _erp_cfg or None)

# Memory-as-a-service: project-parameterized memory tools
register_memory_tools(mcp, _audit)

# Governance: compliance, security, and migration tools (Constitution v3.0)
register_governance_tools(mcp, _audit)


# ── Entry point ──────────────────────────────────────────────────


def main() -> None:
    """Run the Coordination MCP server in stdio mode."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    logger.info("Starting Maude Coordination MCP (stdio)")
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
