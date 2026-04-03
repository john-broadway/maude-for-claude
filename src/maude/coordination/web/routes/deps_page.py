# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Dependencies page."""

import json

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

router = APIRouter()


@router.get("/dependencies", response_class=HTMLResponse)
async def dependencies_page(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Dependencies — interactive dependency graph."""
    all_rooms = state.deps.all_rooms
    graph_data = []
    for room in all_rooms:
        graph_data.append({
            "room": room,
            "depends_on": state.deps.depends_on(room),
            "depended_by": state.deps.depended_by(room),
        })

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "dependencies.html", {
        "rooms": graph_data,
        "graph_json": json.dumps(graph_data),
    })
