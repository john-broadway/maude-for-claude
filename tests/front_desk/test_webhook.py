# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for the Gitea webhook handler."""

from unittest.mock import AsyncMock, MagicMock, patch

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
    mock_memory.all_rooms_summary = AsyncMock(return_value=[])
    mock_memory.recent_incidents = AsyncMock(return_value=[])
    mock_memory.recent_escalations = AsyncMock(return_value=[])
    mock_memory.recent_activity = AsyncMock(return_value=[])
    mock_memory.close = AsyncMock()

    mock_deps = MagicMock()
    mock_deps.all_rooms = ["site-a/my-service", "site-a/postgresql"]
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

    _state["memory"] = mock_memory
    _state["deps"] = mock_deps
    _state["briefing"] = mock_briefing
    _state["chat_llm"] = mock_llm
    _state["chat_store"] = chat_store
    _state["chat_agent"] = chat_agent
    _state["fleet"] = fleet
    _state["agency_router"] = agency_router
    _state["concierge_logger"] = None

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
    app.state.entra = EntraAuth({})
    app.state.auth_redis = None

    yield

    _state.clear()


@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=True)


def _gitea_push_payload(repo_name: str, ref: str = "refs/heads/main", pusher: str = "john") -> dict:
    """Build a minimal Gitea push webhook payload."""
    return {
        "ref": ref,
        "repository": {"name": repo_name, "full_name": f"Maude/{repo_name}"},
        "pusher": {"login": pusher},
    }


# ── Webhook Status ─────────────────────────────────────────────


def test_webhook_status(client: TestClient):
    """GET /webhook/status returns ready."""
    resp = client.get("/webhook/status")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ready"
    assert "/webhook/gitea" in data["endpoints"]


# ── Main Branch Push ───────────────────────────────────────────


@patch("maude.coordination.web.routes.webhook.EventPublisher")
@patch("maude.coordination.web.routes.webhook.DependencyGraph")
def test_webhook_main_branch(mock_deps_cls, mock_pub_cls, client: TestClient):
    """Webhook processes main branch push and signals rooms."""
    # Set up mock DependencyGraph
    mock_deps = MagicMock()
    mock_deps._room_meta = {
        "site-a/my-service": {
            "project": "industrial/example-scada",
            "ip": "localhost",
            "mcp_port": 9801,
            "site": "site-a",
        },
    }
    mock_deps_cls.return_value = mock_deps

    # Set up mock EventPublisher
    mock_pub = AsyncMock()
    mock_pub.publish = AsyncMock(return_value=True)
    mock_pub_cls.return_value = mock_pub

    resp = client.post("/webhook/gitea", json=_gitea_push_payload("example-scada"))
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["repo"] == "example-scada"
    assert data["action"] == "self_deploy"
    assert data["pusher"] == "john"
    assert len(data["rooms_signaled"]) == 1
    assert data["rooms_signaled"][0]["room"] == "my-service"
    assert data["rooms_signaled"][0]["signaled"] is True

    # Verify EventPublisher was used correctly
    mock_pub.connect.assert_awaited_once()
    mock_pub.publish.assert_awaited_once()
    call_args = mock_pub.publish.call_args
    assert call_args[0][0] == "deploy_requested"
    assert call_args[0][1]["repo"] == "example-scada"
    assert call_args[0][1]["action"] == "self_deploy"
    mock_pub.close.assert_awaited_once()


@patch("maude.coordination.web.routes.webhook.EventPublisher")
@patch("maude.coordination.web.routes.webhook.DependencyGraph")
def test_webhook_maude_self_update(mock_deps_cls, mock_pub_cls, client: TestClient):
    """Maude repo push triggers self_update action."""
    mock_deps = MagicMock()
    mock_deps._room_meta = {
        "site-a/maude": {
            "project": "maude",
            "ip": "localhost",
            "mcp_port": 9500,
            "site": "site-a",
        },
    }
    mock_deps_cls.return_value = mock_deps

    mock_pub = AsyncMock()
    mock_pub.publish = AsyncMock(return_value=True)
    mock_pub_cls.return_value = mock_pub

    resp = client.post("/webhook/gitea", json=_gitea_push_payload("maude"))
    assert resp.status_code == 200
    data = resp.json()
    assert data["action"] == "self_update"


# ── Skip Non-Main Branch ──────────────────────────────────────


def test_webhook_skip_non_main(client: TestClient):
    """Webhook skips non-main branches."""
    resp = client.post(
        "/webhook/gitea",
        json=_gitea_push_payload("my-service", ref="refs/heads/feature/xyz"),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "skipped"
    assert "feature/xyz" in data["reason"]


# ── Invalid Payloads ──────────────────────────────────────────


def test_webhook_invalid_json(client: TestClient):
    """Webhook returns 400 for invalid JSON."""
    resp = client.post(
        "/webhook/gitea",
        content=b"not json at all",
        headers={"content-type": "application/json"},
    )
    assert resp.status_code == 400
    assert resp.json()["error"] == "invalid JSON"


def test_webhook_missing_repo_name(client: TestClient):
    """Webhook returns 400 when repository name is missing."""
    resp = client.post("/webhook/gitea", json={"ref": "refs/heads/main"})
    assert resp.status_code == 400
    assert resp.json()["error"] == "no repository name"


# ── No Matching Rooms ─────────────────────────────────────────


@patch("maude.coordination.web.routes.webhook.DependencyGraph")
def test_webhook_no_targets(mock_deps_cls, client: TestClient):
    """Webhook returns no_targets when repo matches no rooms."""
    mock_deps = MagicMock()
    mock_deps._room_meta = {}
    mock_deps_cls.return_value = mock_deps

    resp = client.post(
        "/webhook/gitea",
        json=_gitea_push_payload("unknown-repo"),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "no_targets"
    assert data["repo"] == "unknown-repo"


# ── Multi-Site Rooms ──────────────────────────────────────────


@patch("maude.coordination.web.routes.webhook.EventPublisher")
@patch("maude.coordination.web.routes.webhook.DependencyGraph")
def test_webhook_multi_site(mock_deps_cls, mock_pub_cls, client: TestClient):
    """Webhook signals rooms across multiple sites."""
    mock_deps = MagicMock()
    mock_deps._room_meta = {
        "site-a/postgresql": {
            "project": "infrastructure/postgresql",
            "ip": "localhost",
            "mcp_port": 9870,
            "site": "site-a",
        },
        "site-b/postgresql": {
            "project": "infrastructure/postgresql",
            "ip": "localhost",
            "mcp_port": 9870,
            "site": "site-b",
        },
    }
    mock_deps_cls.return_value = mock_deps

    mock_pub = AsyncMock()
    mock_pub.publish = AsyncMock(return_value=True)
    mock_pub_cls.return_value = mock_pub

    resp = client.post("/webhook/gitea", json=_gitea_push_payload("postgresql"))
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert len(data["rooms_signaled"]) == 2

    rooms = {s["room"] for s in data["rooms_signaled"]}
    sites = {s["site"] for s in data["rooms_signaled"]}
    assert rooms == {"postgresql"}
    assert sites == {"site-a", "site-b"}


# ── Master Branch ─────────────────────────────────────────────


@patch("maude.coordination.web.routes.webhook.EventPublisher")
@patch("maude.coordination.web.routes.webhook.DependencyGraph")
def test_webhook_master_branch(mock_deps_cls, mock_pub_cls, client: TestClient):
    """Webhook also accepts refs/heads/master."""
    mock_deps = MagicMock()
    mock_deps._room_meta = {
        "site-a/gitea": {
            "project": "infrastructure/gitea",
            "ip": "localhost",
            "mcp_port": 9860,
            "site": "site-a",
        },
    }
    mock_deps_cls.return_value = mock_deps

    mock_pub = AsyncMock()
    mock_pub.publish = AsyncMock(return_value=True)
    mock_pub_cls.return_value = mock_pub

    resp = client.post(
        "/webhook/gitea",
        json=_gitea_push_payload("gitea", ref="refs/heads/master"),
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
