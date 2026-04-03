# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Room detail page."""

import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/room/{room_name}", response_class=HTMLResponse)
async def room_detail(
    request: Request, room_name: str, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Room detail — deep dive into a single room."""
    deps_on = state.deps.depends_on(room_name)
    dep_by = state.deps.depended_by(room_name)
    affected = state.deps.affected_by(room_name)

    # Each DB call degrades independently — partial data is better than none.
    try:
        summaries = await state.memory.all_rooms_summary(minutes=1440)
        summary = next((s for s in summaries if s["project"] == room_name), None)
    except Exception:
        logger.warning("Room detail: summary unavailable for %s", room_name, exc_info=True)
        summary = None

    try:
        incidents = await state.memory.recent_incidents(minutes=1440)
        room_incidents = [i for i in incidents if i.get("project") == room_name][:20]
    except Exception:
        logger.warning("Room detail: incidents unavailable for %s", room_name, exc_info=True)
        room_incidents = []

    try:
        activity = await state.memory.project_activity(room_name, minutes=1440, limit=50)
        health_history = [a for a in activity if a.get("model") == "health_loop"][:10]
        agent_history = [a for a in activity if a.get("model") != "health_loop"][:10]
    except Exception:
        logger.warning("Room detail: activity unavailable for %s", room_name, exc_info=True)
        health_history = []
        agent_history = []

    try:
        autonomy = await state.memory.autonomy_status(minutes_recent=3, minutes_history=1440)
        recent_rooms = {s["project"] for s in autonomy if s.get("is_recent")}
    except Exception:
        logger.warning("Room detail: autonomy unavailable for %s", room_name, exc_info=True)
        recent_rooms = set()

    deps_health = [
        {"name": dep, "healthy": dep in recent_rooms}
        for dep in deps_on
    ]

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "room_detail.html", {
        "room_name": room_name,
        "depends_on": deps_on,
        "depended_by": dep_by,
        "affected_by": affected,
        "summary": summary,
        "incidents": room_incidents,
        "health_history": health_history,
        "agent_history": agent_history,
        "deps_health": deps_health,
    })
