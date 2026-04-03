# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Dedicated chat page — deep conversation with Maude or a specific department."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

router = APIRouter()


@router.get("/chat", response_class=HTMLResponse)
async def chat_page(request: Request, dept: str = "", context: str = "") -> HTMLResponse:
    """Dedicated chat page with optional department pre-routing.

    Query params:
        dept: Pre-route to a specific department (e.g., ?dept=quality)
        context: Seed the conversation with context from search
    """
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "pages/chat.html", {
        "dept": dept,
        "context": context,
    })
