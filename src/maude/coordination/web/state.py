# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Typed application state for the Maude Dashboard.

Replaces the old module-level ``_state: dict[str, Any]`` with a typed
dataclass, exposed via FastAPI dependency injection.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from fastapi import Request

if TYPE_CHECKING:
    from maude.coordination.briefing import BriefingGenerator
    from maude.coordination.cross_room_memory import CrossRoomMemory
    from maude.coordination.dependencies import DependencyGraph
    from maude.coordination.web.chat.agent import ChatAgent
    from maude.coordination.web.chat.logger import ConciergeLogger
    from maude.coordination.web.chat.sessions import ChatSessionStore
    from maude.coordination.web.services.agency_router import AgencyRouter
    from maude.coordination.web.services.document_search import DocumentSearch
    from maude.coordination.web.services.fleet import FleetService
    from maude.llm.router import LLMRouter


@dataclass
class AppState:
    """All shared components for the dashboard."""

    memory: CrossRoomMemory
    deps: DependencyGraph
    briefing: BriefingGenerator
    chat_llm: LLMRouter
    chat_store: ChatSessionStore
    chat_agent: ChatAgent
    agents: dict[str, dict[str, Any]]
    fleet: FleetService
    agency_router: AgencyRouter
    document_search: DocumentSearch | None = None
    concierge_logger: ConciergeLogger | None = None


def get_state(request: Request) -> AppState:
    """FastAPI dependency — retrieve typed dashboard state."""
    return request.app.state.dashboard  # type: ignore[no-any-return]


def get_fleet(request: Request) -> FleetService:
    """FastAPI dependency — retrieve FleetService."""
    return request.app.state.dashboard.fleet  # type: ignore[no-any-return]
