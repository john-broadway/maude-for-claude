# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Maude Maude web dashboard (FastAPI + HTMX)."""

from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from maude.coordination.web.app import TEMPLATE_DIR, _state, app
from maude.coordination.web.auth.entra import EntraAuth
from maude.coordination.web.chat import ChatAgent, ChatSessionStore
from maude.coordination.web.services.agency_router import AgencyRouter
from maude.coordination.web.services.fleet import FleetService
from maude.coordination.web.state import AppState
from maude.llm.router import LLMResponse, LLMRouter


@pytest.fixture(autouse=True)
def mock_state():
    """Set up mock components in app state."""
    mock_memory = AsyncMock()
    mock_memory.all_rooms_summary = AsyncMock(
        return_value=[
            {
                "project": "my-service",
                "total_runs": 5,
                "resolved": 4,
                "failed": 1,
                "escalated": 0,
                "no_action": 0,
            },
            {
                "project": "postgresql",
                "total_runs": 3,
                "resolved": 3,
                "failed": 0,
                "escalated": 0,
                "no_action": 0,
            },
        ]
    )
    mock_memory.recent_incidents = AsyncMock(
        return_value=[
            {
                "project": "my-service",
                "trigger": "health_loop",
                "outcome": "resolved",
                "summary": "PLC check passed",
                "created_at": "2026-02-01T19:00:00",
            },
        ]
    )
    mock_memory.recent_escalations = AsyncMock(return_value=[])
    mock_memory.recent_activity = AsyncMock(
        return_value=[
            {
                "project": "my-service",
                "trigger": "scheduled",
                "outcome": "resolved",
                "summary": "Routine check",
                "model": "qwen2.5:7b",
                "tokens_used": 500,
                "created_at": "2026-02-01T19:00:00",
            },
        ]
    )
    mock_memory.close = AsyncMock()

    mock_deps = MagicMock()
    mock_deps.all_rooms = [
        "my-service",
        "monitoring",
        "hmi",
        "influxdb",
        "loki",
        "ollama",
        "postgresql",
        "prometheus",
        "qdrant",
        "uptime-kuma",
        "webui",
        "gitea",
        "pbs",
    ]
    mock_deps.depends_on.return_value = []
    mock_deps.depended_by.return_value = []
    mock_deps.affected_by.return_value = []

    from maude.coordination.briefing import BriefingGenerator

    mock_briefing = AsyncMock(spec=BriefingGenerator)
    mock_briefing.generate = AsyncMock(return_value="== Briefing ==")
    mock_briefing.room_status = AsyncMock(return_value="ROOM STATUS GRID")

    mock_llm = AsyncMock(spec=LLMRouter)
    mock_llm.send = AsyncMock(
        return_value=LLMResponse(
            content="Good evening.",
            tool_calls=[],
            model="test",
            tokens_used=10,
        )
    )
    mock_llm.close = AsyncMock()

    chat_store = ChatSessionStore()
    chat_agent = ChatAgent(
        llm=mock_llm,
        memory=mock_memory,
        deps=mock_deps,
        briefing=mock_briefing,
    )
    fleet = FleetService(mock_memory, mock_deps)
    agency_router = AgencyRouter({})

    # Populate _state for backward-compat references in tests.
    _state["memory"] = mock_memory
    _state["deps"] = mock_deps
    _state["briefing"] = mock_briefing
    _state["chat_llm"] = mock_llm
    _state["chat_store"] = chat_store
    _state["chat_agent"] = chat_agent
    _state["fleet"] = fleet
    _state["agency_router"] = agency_router
    _state["concierge_logger"] = None

    # Set typed state on app (routes use Depends(get_state)).
    app.state.dashboard = AppState(
        memory=mock_memory,
        deps=mock_deps,
        briefing=mock_briefing,
        chat_llm=mock_llm,
        chat_store=chat_store,
        chat_agent=chat_agent,
        agents={},
        fleet=fleet,
        agency_router=agency_router,
        concierge_logger=None,
    )
    app.state.templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
    app.state.entra = EntraAuth({})  # Disabled — no credentials.
    app.state.auth_redis = None

    yield

    _state.clear()


@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=True)


# ── Health ──────────────────────────────────────────────────────


def test_health_endpoint(client: TestClient):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["service"] == "concierge-coordinator"


# ── Home ────────────────────────────────────────────────────────


def test_home_returns_search_page(client: TestClient):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "Maude" in resp.text
    assert "How may I help you?" in resp.text


# ── Operations (formerly Lobby) ────────────────────────────────


def test_operations_returns_html(client: TestClient):
    resp = client.get("/operations")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "Operations" in resp.text


def test_operations_shows_room_cards(client: TestClient):
    resp = client.get("/operations")
    assert "my-service" in resp.text
    assert "postgresql" in resp.text


def test_operations_shows_autonomy_badges(client: TestClient):
    """Operations page uses autonomy status badges."""
    resp = client.get("/operations")
    badges = ("badge-autonomous", "badge-degraded", "badge-manual")
    assert any(b in resp.text for b in badges)


# ── Room Detail ─────────────────────────────────────────────────


def test_room_detail_returns_html(client: TestClient):
    resp = client.get("/room/my-service")
    assert resp.status_code == 200
    assert "my-service" in resp.text


def test_room_detail_shows_incidents(client: TestClient):
    resp = client.get("/room/my-service")
    assert "PLC check passed" in resp.text


# ── Dependencies ────────────────────────────────────────────────


def test_dependencies_page(client: TestClient):
    resp = client.get("/dependencies")
    assert resp.status_code == 200
    assert "Dependencies" in resp.text


# ── Memory ──────────────────────────────────────────────────────


def test_memory_page(client: TestClient):
    resp = client.get("/memory")
    assert resp.status_code == 200
    assert "Memory" in resp.text
    assert "Routine check" in resp.text


# ── HTMX Fragments ─────────────────────────────────────────────


def test_htmx_room_cards(client: TestClient):
    resp = client.get("/htmx/room-cards")
    assert resp.status_code == 200
    assert "my-service" in resp.text


def test_htmx_briefing(client: TestClient):
    resp = client.get("/htmx/briefing?minutes=60")
    assert resp.status_code == 200
    assert "Briefing" in resp.text


def test_htmx_incidents(client: TestClient):
    resp = client.get("/htmx/incidents?minutes=60")
    assert resp.status_code == 200
    assert "PLC check passed" in resp.text


def test_htmx_incidents_empty(client: TestClient):
    app.state.dashboard.memory.recent_incidents = AsyncMock(return_value=[])
    resp = client.get("/htmx/incidents?minutes=60")
    assert resp.status_code == 200
    assert "No incidents" in resp.text


# ── Static Files ──────────────────────────────────────────────────


def test_static_css_served(client: TestClient):
    """Art Deco CSS file is served from /static/."""
    resp = client.get("/static/css/art-deco.css")
    assert resp.status_code == 200
    assert "text/css" in resp.headers["content-type"]


# ── Operations Command Center ─────────────────────────────────────


def test_operations_has_command_center(client: TestClient):
    """Operations page contains the command center layout."""
    resp = client.get("/operations")
    assert resp.status_code == 200
    assert "Command Center" in resp.text


# ── Chat API ─────────────────────────────────────────────────────


def test_chat_endpoint_returns_sse(client: TestClient):
    """POST /api/chat returns event-stream content type."""
    resp = client.post("/api/chat", json={"message": "hello", "session_id": "test-web"})
    assert resp.status_code == 200
    assert "text/event-stream" in resp.headers["content-type"]


def test_chat_reset_endpoint(client: TestClient):
    """POST /api/chat/reset clears session."""
    app.state.dashboard.chat_store.get_or_create("reset-test")
    resp = client.post("/api/chat/reset", json={"session_id": "reset-test"})
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
