# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Operations — system-wide status overview (formerly Lobby)."""

import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/operations", response_class=HTMLResponse)
async def operations(request: Request, state: AppState = Depends(get_state)) -> HTMLResponse:
    """Operations — system-wide status overview with autonomy badges."""
    rooms_data, _fleet = await state.fleet.get_autonomy_data()

    for room in rooms_data:
        room["web_url"] = state.deps.web_url(room["name"])

    autonomous = sum(1 for r in rooms_data if r["status"] == "autonomous")
    degraded = sum(1 for r in rooms_data if r["status"] == "degraded")
    manual = sum(1 for r in rooms_data if r["status"] == "manual")

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "pages/operations.html", {
        "rooms": rooms_data,
        "total_rooms": len(rooms_data),
        "autonomous_count": autonomous,
        "degraded_count": degraded,
        "manual_count": manual,
    })


@router.get("/htmx/room-cards", response_class=HTMLResponse)
async def htmx_room_cards(request: Request, state: AppState = Depends(get_state)) -> HTMLResponse:
    """HTMX fragment — refreshable room grid tiles."""
    rooms_data, _fleet = await state.fleet.get_autonomy_data()

    for room in rooms_data:
        room["web_url"] = state.deps.web_url(room["name"])

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "fragments/room_cards.html", {
        "rooms": rooms_data,
    })


@router.get("/htmx/briefing", response_class=HTMLResponse)
async def htmx_briefing(
    request: Request, minutes: int = 60, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """HTMX fragment — briefing text."""
    try:
        text = await state.briefing.generate(scope="all", minutes=minutes)
    except Exception:
        logger.warning("Lobby: briefing generation failed", exc_info=True)
        text = "Briefing temporarily unavailable."
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "fragments/briefing.html", {
        "briefing_text": text,
    })


@router.get("/htmx/incidents", response_class=HTMLResponse)
async def htmx_incidents(
    request: Request, minutes: int = 60, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """HTMX fragment — recent incidents table."""
    try:
        incidents = await state.memory.recent_incidents(minutes=minutes)
    except Exception:
        logger.warning("Lobby: incidents unavailable", exc_info=True)
        incidents = []
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "fragments/incidents.html", {
        "incidents": incidents[:30],
    })
