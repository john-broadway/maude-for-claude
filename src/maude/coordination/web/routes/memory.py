# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Memory browser page."""

import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/memory", response_class=HTMLResponse)
async def memory_page(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Memory — cross-room memory browser."""
    try:
        activity = await state.memory.recent_activity(minutes=120)
    except Exception:
        logger.warning("Memory browser: database unavailable", exc_info=True)
        activity = []

    templates = request.app.state.templates
    return templates.TemplateResponse(request, "memory.html", {
        "activity": activity[:50],
    })
