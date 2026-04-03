# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Autonomy page — room health and self-healing status."""

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

router = APIRouter()


@router.get("/autonomy", response_class=HTMLResponse)
async def autonomy_page(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Autonomy — room health and self-healing status."""
    rooms_data, fleet = await state.fleet.get_autonomy_data()

    autonomous = sum(1 for r in rooms_data if r["status"] == "autonomous")
    degraded = sum(1 for r in rooms_data if r["status"] == "degraded")
    manual = sum(1 for r in rooms_data if r["status"] == "manual")

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "autonomy.html", {
        "rooms": rooms_data,
        "total_rooms": len(rooms_data),
        "autonomous_count": autonomous,
        "degraded_count": degraded,
        "manual_count": manual,
        "fleet_health_checks_24h": fleet.get("total_health_checks", 0),
        "fleet_restarts_24h": fleet.get("total_restarts", 0),
        "fleet_escalations_24h": fleet.get("total_escalations", 0),
    })


@router.get("/htmx/autonomy-grid", response_class=HTMLResponse)
async def htmx_autonomy_grid(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """HTMX fragment — refreshable autonomy grid."""
    rooms_data, _fleet = await state.fleet.get_autonomy_data()
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "fragments/autonomy_grid.html", {
        "rooms": rooms_data,
    })
