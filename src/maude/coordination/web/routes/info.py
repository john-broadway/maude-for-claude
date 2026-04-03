# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""How It Works page."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

router = APIRouter()


@router.get("/how-it-works", response_class=HTMLResponse)
async def how_it_works_page(request: Request) -> HTMLResponse:
    """How It Works — visual guide to autonomous self-healing and learning."""
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "how-it-works.html", {})
