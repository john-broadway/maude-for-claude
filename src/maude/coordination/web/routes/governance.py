# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Governance routes — executive story, accountability matrix, compliance audit."""

import json
import logging
import os
from collections import defaultdict
from pathlib import Path
from typing import Any

import yaml
from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

logger = logging.getLogger(__name__)
router = APIRouter()

GOVERNANCE_DIR = Path(os.environ.get("AGENCY_ROOT", "/app/agency")) / "governance"

_ACCOUNTABILITY_CACHE: dict[str, Any] | None = None
_AUDIT_CACHE: dict[str, Any] | None = None


def _load_accountability() -> dict[str, Any]:
    """Load accountability.yaml, cached at module level."""
    global _ACCOUNTABILITY_CACHE
    if _ACCOUNTABILITY_CACHE is not None:
        return _ACCOUNTABILITY_CACHE
    path = GOVERNANCE_DIR / "accountability.yaml"
    if path.exists():
        data = yaml.safe_load(path.read_text()) or {}
        _ACCOUNTABILITY_CACHE = data
        return data
    return {}


def _load_audit_results() -> dict[str, Any]:
    """Load audit-results.json, cached at module level."""
    global _AUDIT_CACHE
    if _AUDIT_CACHE is not None:
        return _AUDIT_CACHE
    path = GOVERNANCE_DIR / "audit-results.json"
    if path.exists():
        data = json.loads(path.read_text())
        _AUDIT_CACHE = data
        return data
    return {}


def _build_governance_js(data: dict[str, Any]) -> dict[str, Any]:
    """Build the GOVERNANCE JS object from accountability.yaml data.

    The output matches the exact structure expected by the matrix JS:
        { actors[], domains[], access{}, gaps[] }
    """
    actors = data.get("actors", [])
    domains_raw = data.get("domains", [])
    gaps_raw = data.get("gaps", [])

    # Build actors list for JS
    js_actors = []
    for a in actors:
        js_actor: dict[str, Any] = {
            "id": a["id"],
            "name": a["name"],
            "type": a["type"],
        }
        for field in ("ctid", "ip", "site", "sites", "model", "layer"):
            if field in a:
                js_actor[field] = a[field]
        js_actors.append(js_actor)

    # Build domains list for JS — derive short name from id
    _domain_short: dict[str, str] = {
        "database": "DB",
        "plc": "PLC",
        "service-lifecycle": "Svc",
        "monitoring": "Mon",
        "memory": "Mem",
        "compliance-security": "C&S",
        "version-control": "Ver",
        "code-files": "Code",
        "source-control": "Git",
        "plc-collection": "Chron",
        "hmi": "HMI",
        "availability": "Avail",
        "time-series": "TSDB",
        "vector-search": "Qdrant",
        "cache": "Cache",
        "metrics": "Prom",
        "logs": "Logs",
        "network": "Net",
        "dns": "DNS",
        "gpu-inference": "GPU",
        "lab-mes": "Lab",
        "coordination": "Coord",
        "agents": "Agents",
        "code-reviewers": "Rev",
    }
    js_domains = []
    for d in domains_raw:
        did = d["id"]
        js_domains.append(
            {
                "id": did,
                "name": _domain_short.get(did, did[:4].upper()),
                "fullName": d.get("name", did),
            }
        )

    # Build access object from domains.actions
    access: dict[str, dict[str, Any]] = defaultdict(dict)

    # Map access level from YAML action access to JS level
    def _map_level(access_str: str) -> str:
        _lvl_map = {
            "read-only": "read",
            "read-write": "gap",
            "write": "guard",
            "destructive": "guard",
        }
        return _lvl_map.get(access_str, "read")

    for domain in domains_raw:
        did = domain["id"]
        for action in domain.get("actions", []):
            tool = action.get("tool", "")
            access_level = _map_level(action.get("access", "read-only"))
            guards_raw = action.get("guard", [])
            guards: list[str] = [guards_raw] if isinstance(guards_raw, str) else list(guards_raw)
            note = action.get("note", "")

            # Determine if this action has a gap
            gap_id: str | None = None
            for g in gaps_raw:
                if g.get("domain") == did and "G1" in note and g["id"] == "G1":
                    gap_id = g["id"]
                    break

            # Find which actors have access to this domain via this action
            actor_refs = action.get("actors", [])
            for actor_ref in actor_refs:
                actor_id = str(actor_ref)
                # Skip meta-references like "room:self" or "all rooms via..."
                if actor_id.startswith("all ") or actor_id == "room:self":
                    continue
                if did not in access[actor_id]:
                    access[actor_id][did] = {
                        "level": access_level,
                        "tools": [],
                        "guards": guards[:],
                        "gap": gap_id,
                    }
                else:
                    existing = access[actor_id][did]
                    if tool and tool not in existing["tools"]:
                        existing["tools"].append(tool)
                    continue
                if tool:
                    access[actor_id][did]["tools"].append(tool)

    # Also wire up actor-level tools_read/tools_write to their domains
    for actor in actors:
        actor_id = actor["id"]
        tools_read = actor.get("tools_read", [])
        tools_write = actor.get("tools_write", [])
        guards_list = actor.get("guards", [])
        guards_strs = [str(g) for g in guards_list]

        # If actor declares domains, ensure service-lifecycle is present for maude-rooms
        if actor.get("type") == "maude-room":
            if "service-lifecycle" not in access[actor_id]:
                write_tools = [t for t in tools_write if "restart" in t or "kill_switch" in t]
                access[actor_id]["service-lifecycle"] = {
                    "level": "guard",
                    "tools": write_tools,
                    "guards": guards_strs,
                    "gap": None,
                }
            if "memory" not in access[actor_id]:
                mem_tools = [t for t in tools_read if "memory" in t]
                if mem_tools:
                    access[actor_id]["memory"] = {
                        "level": "read",
                        "tools": mem_tools,
                        "guards": ["per-room"],
                        "gap": None,
                    }

    # Build gaps list for JS
    js_gaps = []
    for g in gaps_raw:
        js_gap: dict[str, Any] = {
            "id": g["id"],
            "severity": g["severity"],
            "domain": g["domain"],
            "status": g["status"],
            "issue": g["issue"],
            "fix": g.get("fix", ""),
        }
        if "residual_risk" in g:
            js_gap["residual"] = g["residual_risk"]
        js_gaps.append(js_gap)

    return {
        "actors": js_actors,
        "domains": js_domains,
        "access": dict(access),
        "gaps": js_gaps,
    }


def _build_rooms_by_layer(rooms_data: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """Group rooms by layer for the governance overview page."""
    accountability = _load_accountability()
    actors = {a["id"]: a for a in accountability.get("actors", [])}

    layer_order = [
        "control",
        "maude_layer",
        "data",
        "observability",
        "industrial",
        "infrastructure",
        "compute",
    ]
    layer_labels = {
        "control": "Control",
        "maude_layer": "Maude",
        "data": "Data",
        "observability": "Observability",
        "industrial": "Industrial",
        "infrastructure": "Infrastructure",
        "compute": "Compute",
    }

    by_layer: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for room in rooms_data:
        name = room["name"]
        actor = actors.get(f"room:{name}", {})
        layer = actor.get("layer", "other")
        site = actor.get("site", "slc")
        by_layer[layer].append({"name": name, "site": site})

    # Preserve defined order
    ordered: dict[str, list[dict[str, Any]]] = {}
    for layer in layer_order:
        label = layer_labels.get(layer, layer.capitalize())
        if by_layer[layer]:
            ordered[label] = by_layer[layer]
    # Catch anything not in the defined order
    for layer, rooms in by_layer.items():
        label = layer_labels.get(layer, layer.capitalize())
        if label not in ordered and rooms:
            ordered[label] = rooms

    return ordered


def _agent_stats(agents: dict[str, Any]) -> dict[str, int]:
    """Count agents by company from the agents dict."""
    by_company: dict[str, int] = defaultdict(int)
    for dept_key in agents:
        # dept_key format: "hp:production", "corporate:admin", etc.
        company = dept_key.split(":")[0] if ":" in dept_key else dept_key
        by_company[company] += 1
    return dict(by_company)


@router.get("/governance", response_class=HTMLResponse)
async def governance(request: Request, state: AppState = Depends(get_state)) -> HTMLResponse:
    """Governance overview — executive story page."""
    rooms_data, _fleet = await state.fleet.get_autonomy_data()

    accountability = _load_accountability()
    actors = accountability.get("actors", [])
    gaps = accountability.get("gaps", [])
    sites = accountability.get("sites", [])

    # Count rooms (maude rooms only)
    maude_rooms = [a for a in actors if a.get("type") == "maude-room"]
    room_count = len(maude_rooms)

    # Count tools across all actors
    total_tools = 0
    guarded_tools = 0
    for actor in actors:
        read_tools = actor.get("tools_read", [])
        write_tools = actor.get("tools_write", [])
        all_actor_tools = read_tools + write_tools
        total_tools += len(all_actor_tools)
        guards = actor.get("guards", [])
        if guards:
            guarded_tools += len(all_actor_tools)

    guarded_pct = round(guarded_tools / total_tools * 100) if total_tools else 0

    # Agent count (dept-agent-groups)
    dept_groups = [a for a in actors if a.get("type") == "dept-agent-group"]
    agent_count = sum(a.get("agent_count", 0) for a in dept_groups)

    # Site count (live or deploying)
    active_sites = [s for s in sites if s.get("status") in ("live", "deploying")]
    site_count = max(len(active_sites), 2)

    # Gap stats
    gap_count = len([g for g in gaps if g.get("status") not in ("fixed", "accepted")])

    # Compliance pct — if no audit results, show 0
    audit = _load_audit_results()
    summary = audit.get("summary", {})
    total_checks = summary.get("total_checks", 0)
    passing = summary.get("pass", 0)
    compliance_pct = round(passing / total_checks * 100) if total_checks else 0

    # Rooms by layer
    rooms_by_layer = _build_rooms_by_layer(rooms_data)

    # Agents by company
    agents_by_company = _agent_stats(state.agency_router.agents)
    company_count = len(agents_by_company)

    templates = request.app.state.templates
    return templates.TemplateResponse(
        request,
        "pages/governance.html",
        {
            "active_page": "governance",
            "room_count": room_count,
            "tool_count": total_tools,
            "guarded_pct": guarded_pct,
            "agent_count": agent_count,
            "site_count": site_count,
            "gap_count": gap_count,
            "compliance_pct": compliance_pct,
            "rooms_by_layer": rooms_by_layer,
            "agents_by_company": agents_by_company,
            "company_count": company_count,
        },
    )


@router.get("/governance/accountability", response_class=HTMLResponse)
async def governance_accountability(
    request: Request,
    state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Accountability matrix — who can do what."""
    accountability = _load_accountability()
    governance_js = _build_governance_js(accountability)

    templates = request.app.state.templates
    return templates.TemplateResponse(
        request,
        "pages/accountability.html",
        {
            "active_page": "governance",
            "governance_data": governance_js,
        },
    )


@router.get("/governance/compliance", response_class=HTMLResponse)
async def governance_compliance(
    request: Request,
    state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Compliance audit viewer — constitutional compliance across all projects."""
    audit = _load_audit_results()

    templates = request.app.state.templates
    return templates.TemplateResponse(
        request,
        "pages/compliance.html",
        {
            "active_page": "governance",
            "audit": audit,
            "audit_available": bool(audit),
        },
    )
