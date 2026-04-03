# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Status report route — infrastructure executive report."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

router = APIRouter()


@router.get("/status", response_class=HTMLResponse)
async def status_report(request: Request) -> HTMLResponse:
    """Executive infrastructure status report."""
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "pages/postmortem.html", {
        "active_page": "governance",
    })
