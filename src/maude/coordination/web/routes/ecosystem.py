# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Ecosystem page — infrastructure map."""

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

router = APIRouter()


@router.get("/ecosystem", response_class=HTMLResponse)
async def ecosystem_page(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Ecosystem — floor-to-doors infrastructure map."""
    layers = state.deps.layers()
    infra = state.deps.infrastructure()

    rooms_data, _ = await state.fleet.get_autonomy_data()
    status_map = {r["name"]: r for r in rooms_data}

    for layer in layers:
        enriched_rooms = []
        for room_name in layer.get("rooms", []):
            info = state.deps.room_info(room_name)
            live = status_map.get(room_name, {})
            enriched_rooms.append({
                "name": room_name,
                **info,
                "status": live.get("status", "unknown"),
                "last_outcome": live.get("last_outcome", ""),
            })
        layer["rooms"] = enriched_rooms

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "ecosystem.html", {
        "layers": layers,
        "infrastructure": infra,
        "total_rooms": len(state.deps.all_rooms),
    })


@router.get("/htmx/ecosystem-rooms", response_class=HTMLResponse)
async def htmx_ecosystem_rooms(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """HTMX fragment — refreshable room status within ecosystem layers."""
    layers = state.deps.layers()
    rooms_data, _ = await state.fleet.get_autonomy_data()
    status_map = {r["name"]: r for r in rooms_data}

    for layer in layers:
        enriched_rooms = []
        for room_name in layer.get("rooms", []):
            info = state.deps.room_info(room_name)
            live = status_map.get(room_name, {})
            enriched_rooms.append({
                "name": room_name,
                **info,
                "status": live.get("status", "unknown"),
                "last_outcome": live.get("last_outcome", ""),
            })
        layer["rooms"] = enriched_rooms

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "fragments/ecosystem_rooms.html", {
        "layers": layers,
    })
