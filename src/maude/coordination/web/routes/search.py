# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Search page — unified agency + document + site navigation search."""

import asyncio
import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from maude.coordination.web.state import AppState, get_state

logger = logging.getLogger(__name__)

router = APIRouter()

# Site navigation map — keyword matching for page routing.
_SITE_PAGES: list[dict] = [
    {
        "title": "Chat with Maude",
        "desc": "Ask the concierge anything — briefings, room status, agency questions",
        "url": "/chat",
        "keywords": ["chat", "talk", "ask", "assistant", "maude", "briefing", "help"],
    },
    {
        "title": "Operations",
        "desc": "Fleet status, room health, autonomy scores, dependency map",
        "url": "/operations",
        "keywords": ["operations", "ops", "rooms", "room status", "fleet", "health", "status"],
    },
    {
        "title": "Governance",
        "desc": "The Constitution, how the Maude is built and governed",
        "url": "/governance",
        "keywords": ["governance", "constitution", "rules", "law", "how it works"],
    },
    {
        "title": "Compliance",
        "desc": "Audit results, compliance checks, gap analysis",
        "url": "/governance/compliance",
        "keywords": ["compliance", "audit", "checks", "gaps", "passing"],
    },
    {
        "title": "Accountability",
        "desc": "Who owns what — the accountability matrix",
        "url": "/governance/accountability",
        "keywords": ["accountability", "ownership", "responsible", "who owns"],
    },
    {
        "title": "Ecosystem",
        "desc": "Full system map — every room, layer, and connection",
        "url": "/ecosystem",
        "keywords": ["ecosystem", "map", "architecture", "systems", "infrastructure"],
    },
    {
        "title": "Dependencies",
        "desc": "Service dependency graph — who depends on whom",
        "url": "/dependencies",
        "keywords": ["dependencies", "depends", "graph", "upstream", "downstream"],
    },
    {
        "title": "Autonomy",
        "desc": "Room autonomy scores and self-healing trends",
        "url": "/autonomy",
        "keywords": ["autonomy", "autonomous", "self-healing", "scores"],
    },
    {
        "title": "Memory",
        "desc": "Cross-room memory and knowledge base",
        "url": "/memory",
        "keywords": ["memory", "knowledge", "recall", "remember"],
    },
    {
        "title": "How It Works",
        "desc": "Technical overview of Maude platform",
        "url": "/how-it-works",
        "keywords": ["how it works", "technical", "overview", "explanation"],
    },
]


def _match_pages(query: str) -> list[dict]:
    """Match query against site pages. Returns top matches."""
    q = query.lower()
    scored: list[tuple[float, dict]] = []
    for page in _SITE_PAGES:
        score = 0.0
        for kw in page["keywords"]:
            if kw in q:
                # Longer keyword matches score higher (more specific).
                score = max(score, len(kw) / len(q) if len(q) > 0 else 0)
        if score > 0:
            scored.append((score, page))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [p for _, p in scored[:4]]


@router.get("/search", response_class=HTMLResponse)
async def search_page(request: Request) -> HTMLResponse:
    """Search — query the agency and documents from the browser."""
    templates = request.app.state.templates
    return templates.TemplateResponse(request, "search.html", {})


@router.post("/api/search", response_class=HTMLResponse)
async def api_search(
    request: Request, state: AppState = Depends(get_state),
) -> HTMLResponse:
    """Search API — returns HTMX fragment with results + site navigation."""
    form = await request.form()
    question = str(form.get("question", "")).strip()
    templates = request.app.state.templates

    if not question:
        return templates.TemplateResponse(request, "fragments/search_results.html", {
            "error": "Please enter a question.",
        })

    # Site navigation matches (instant, no async needed).
    nav_matches = _match_pages(question)

    # Run agency routing and document search in parallel.
    agency_coro = _safe_agency_search(state, question)
    doc_coro = _safe_document_search(state, question)

    agency_result, doc_results = await asyncio.gather(agency_coro, doc_coro)

    has_agency = bool(agency_result.get("answer"))
    has_docs = bool(doc_results)
    has_nav = bool(nav_matches)

    # If nothing found at all, show nav suggestions + helpful message.
    if not has_agency and not has_docs and not has_nav:
        return templates.TemplateResponse(request, "fragments/search_results.html", {
            "question": question,
            "no_results": True,
        })

    return templates.TemplateResponse(request, "fragments/search_results.html", {
        "question": question,
        "answer": agency_result.get("answer"),
        "department": agency_result.get("department"),
        "agent_name": agency_result.get("agent_name"),
        "also_relevant": agency_result.get("also_relevant", []),
        "routing": agency_result.get("routing", []),
        "documents": doc_results,
        "nav_matches": nav_matches,
    })


async def _safe_agency_search(state: AppState, question: str) -> dict:
    """Agency search with error handling."""
    try:
        return await state.agency_router.route_and_ask(question)
    except Exception:
        logger.warning("Agency routing failed for: %s", question[:100], exc_info=True)
        return {"error": "Agency search unavailable"}


async def _safe_document_search(
    state: AppState, question: str,
) -> list[dict]:
    """Document search with error handling. Returns empty on failure."""
    if state.document_search is None:
        return []
    try:
        return await state.document_search.search(question)
    except Exception:
        logger.warning("Document search failed for: %s", question[:100], exc_info=True)
        return []
