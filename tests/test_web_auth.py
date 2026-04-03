# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Maude Dashboard authentication — roles, middleware, routes."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from maude.coordination.web.app import TEMPLATE_DIR, _state, app
from maude.coordination.web.auth.entra import EntraAuth
from maude.coordination.web.auth.middleware import (
    SESSION_COOKIE,
    SESSION_TTL,
    AuthMiddleware,
)
from maude.coordination.web.auth.roles import (
    ANONYMOUS_USER,
    DashboardRole,
    DashboardUser,
)
from maude.coordination.web.chat import ChatAgent, ChatSessionStore
from maude.coordination.web.services.agency_router import AgencyRouter
from maude.coordination.web.services.fleet import FleetService
from maude.coordination.web.state import AppState
from maude.llm.router import LLMResponse, LLMRouter


def _make_entra(redirect_uri: str = "http://localhost/auth/callback") -> EntraAuth:
    """Create an EntraAuth that reports enabled=True without hitting real MSAL."""
    entra = EntraAuth({})  # No MSAL init.
    entra._tenant_id = "test-tenant"
    entra._client_id = "test-client"
    entra._client_secret = "test-secret"
    entra._redirect_uri = redirect_uri
    entra._app = MagicMock()
    return entra


# ── Fixtures ───────────────────────────────────────────────────


def _setup_app_state() -> None:
    """Minimal app state for auth testing."""
    mock_memory = AsyncMock()
    mock_memory.all_rooms_summary = AsyncMock(return_value=[])
    mock_memory.recent_incidents = AsyncMock(return_value=[])
    mock_memory.recent_escalations = AsyncMock(return_value=[])
    mock_memory.recent_activity = AsyncMock(return_value=[])
    mock_memory.close = AsyncMock()

    mock_deps = MagicMock()
    mock_deps.all_rooms = ["my-service"]
    mock_deps.depends_on.return_value = []
    mock_deps.depended_by.return_value = []
    mock_deps.affected_by.return_value = []

    from maude.coordination.briefing import BriefingGenerator

    mock_briefing = AsyncMock(spec=BriefingGenerator)
    mock_briefing.generate = AsyncMock(return_value="== Briefing ==")
    mock_briefing.room_status = AsyncMock(return_value="STATUS")

    mock_llm = AsyncMock(spec=LLMRouter)
    mock_llm.send = AsyncMock(
        return_value=LLMResponse(
            content="Hello.",
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

    _state.update(
        {
            "memory": mock_memory,
            "deps": mock_deps,
            "briefing": mock_briefing,
            "chat_llm": mock_llm,
            "chat_store": chat_store,
            "chat_agent": chat_agent,
            "fleet": fleet,
            "agency_router": agency_router,
            "concierge_logger": None,
        }
    )

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


@pytest.fixture(autouse=True)
def _cleanup():
    yield
    _state.clear()
    # Reset middleware to disabled-auth defaults so test order doesn't matter.
    app.state.entra = EntraAuth({})
    app.state.auth_provider = "entra"
    app.state.auth_redis = None
    for mw in app.user_middleware:
        if hasattr(mw, "kwargs"):
            mw.kwargs["entra"] = EntraAuth({})
            mw.kwargs["redis"] = None
            mw.kwargs.pop("admin_ips", None)
    app.middleware_stack = app.build_middleware_stack()


# ── DashboardRole ──────────────────────────────────────────────


class TestDashboardRole:
    def test_role_ordering(self):
        assert DashboardRole.ADMIN > DashboardRole.OPERATOR > DashboardRole.VIEWER

    def test_role_values(self):
        assert DashboardRole.VIEWER == 1
        assert DashboardRole.OPERATOR == 2
        assert DashboardRole.ADMIN == 3


# ── DashboardUser ──────────────────────────────────────────────


class TestDashboardUser:
    def test_admin_permissions(self):
        user = DashboardUser(name="Test", email="a@b.c", role=DashboardRole.ADMIN)
        assert user.is_admin is True
        assert user.is_operator is True
        assert user.has_role(DashboardRole.VIEWER) is True

    def test_operator_permissions(self):
        user = DashboardUser(name="Test", email="a@b.c", role=DashboardRole.OPERATOR)
        assert user.is_admin is False
        assert user.is_operator is True
        assert user.has_role(DashboardRole.VIEWER) is True

    def test_viewer_permissions(self):
        user = DashboardUser(name="Test", email="a@b.c", role=DashboardRole.VIEWER)
        assert user.is_admin is False
        assert user.is_operator is False
        assert user.has_role(DashboardRole.VIEWER) is True
        assert user.has_role(DashboardRole.OPERATOR) is False

    def test_frozen(self):
        user = DashboardUser(name="Test", email="a@b.c", role=DashboardRole.VIEWER)
        with pytest.raises(AttributeError):
            user.name = "Changed"  # type: ignore[misc]

    def test_anonymous_user_is_admin(self):
        assert ANONYMOUS_USER.is_admin is True
        assert ANONYMOUS_USER.name == "Anonymous"


# ── EntraAuth ──────────────────────────────────────────────────


class TestEntraAuth:
    def test_disabled_when_no_config(self):
        entra = EntraAuth({})
        assert entra.enabled is False

    def test_disabled_when_partial_config(self):
        entra = EntraAuth({"tenant_id": "abc", "client_id": "def"})
        assert entra.enabled is False

    def test_get_auth_url_returns_none_when_disabled(self):
        entra = EntraAuth({})
        assert entra.get_auth_url(state="test") is None

    async def test_exchange_code_returns_none_when_disabled(self):
        entra = EntraAuth({})
        result = await entra.exchange_code("fake-code")
        assert result is None

    def test_resolve_role_default_viewer(self):
        entra = EntraAuth({})
        assert entra.resolve_role([]) == "viewer"

    def test_resolve_role_maps_groups(self):
        entra = EntraAuth(
            {
                "group_mapping": {
                    "group-admin": "admin",
                    "group-ops": "operator",
                },
            }
        )
        assert entra.resolve_role(["group-admin"]) == "admin"
        assert entra.resolve_role(["group-ops"]) == "operator"
        assert entra.resolve_role(["unknown-group"]) == "viewer"

    def test_resolve_role_picks_highest(self):
        entra = EntraAuth(
            {
                "group_mapping": {
                    "g1": "operator",
                    "g2": "admin",
                },
            }
        )
        assert entra.resolve_role(["g1", "g2"]) == "admin"


# ── AuthMiddleware ─────────────────────────────────────────────


class TestAuthMiddlewareDisabled:
    """Tests with auth disabled (no Entra credentials)."""

    def test_all_routes_accessible(self):
        _setup_app_state()
        app.state.entra = EntraAuth({})
        app.state.auth_redis = None
        client = TestClient(app, raise_server_exceptions=True)

        resp = client.get("/")
        assert resp.status_code == 200
        # Identity chip hidden when auth is disabled.
        assert "Anonymous" not in resp.text

    def test_health_accessible(self):
        _setup_app_state()
        app.state.entra = EntraAuth({})
        app.state.auth_redis = None
        client = TestClient(app, raise_server_exceptions=True)

        resp = client.get("/health")
        assert resp.status_code == 200

    def test_login_redirects_home_when_disabled(self):
        _setup_app_state()
        app.state.entra = EntraAuth({})
        app.state.auth_redis = None
        client = TestClient(app, raise_server_exceptions=False)

        resp = client.get("/login", follow_redirects=False)
        assert resp.status_code == 302
        assert resp.headers["location"] == "/"

    def test_logout_clears_cookie(self):
        _setup_app_state()
        app.state.entra = EntraAuth({})
        app.state.auth_redis = None
        client = TestClient(app, raise_server_exceptions=True)

        resp = client.get("/logout", follow_redirects=False)
        assert resp.status_code == 302


class TestAuthMiddlewareEnabled:
    """Tests with auth enabled (mock Entra credentials)."""

    @staticmethod
    def _setup_with_auth(admin_ips: list[str] | None = None) -> TestClient:
        _setup_app_state()
        entra = _make_entra()
        app.state.entra = entra

        # Mock Redis for session storage.
        mock_redis = AsyncMock()
        mock_redis.get = AsyncMock(return_value=None)
        mock_redis.set = AsyncMock(return_value=True)
        mock_redis.delete = AsyncMock(return_value=True)
        app.state.auth_redis = mock_redis

        # Update middleware with real entra + redis.
        # Middleware was created at import time with EntraAuth({}).
        # We need to update the middleware's internal references.
        for mw in app.user_middleware:
            if hasattr(mw, "kwargs"):
                mw.kwargs["entra"] = entra
                mw.kwargs["redis"] = mock_redis
                if admin_ips:
                    mw.kwargs["admin_ips"] = admin_ips

        # Rebuild middleware stack so changes take effect.
        app.middleware_stack = app.build_middleware_stack()

        return TestClient(app, raise_server_exceptions=False)

    def test_unauthenticated_redirects_to_login(self):
        client = self._setup_with_auth()

        resp = client.get("/", follow_redirects=False)
        assert resp.status_code == 302
        assert "/login" in resp.headers["location"]

    def test_health_always_public(self):
        client = self._setup_with_auth()

        resp = client.get("/health")
        assert resp.status_code == 200

    def test_static_always_public(self):
        client = self._setup_with_auth()

        resp = client.get("/static/css/art-deco.css")
        assert resp.status_code == 200

    def test_valid_session_grants_access(self):
        client = self._setup_with_auth()

        session_data = json.dumps(
            {
                "name": "Test User",
                "email": "user@example.com",
                "role": DashboardRole.ADMIN.value,
            }
        )
        app.state.auth_redis.get = AsyncMock(return_value=session_data)

        client.cookies.set(SESSION_COOKIE, "valid-session-id")
        resp = client.get("/")
        assert resp.status_code == 200
        assert "Test User" in resp.text

    def test_invalid_session_redirects(self):
        client = self._setup_with_auth()

        app.state.auth_redis.get = AsyncMock(return_value=None)

        client.cookies.set(SESSION_COOKIE, "expired-session")
        resp = client.get("/", follow_redirects=False)
        assert resp.status_code == 302
        assert "/login" in resp.headers["location"]

    def test_admin_ip_bypass(self):
        client = self._setup_with_auth(admin_ips=["testclient"])

        resp = client.get("/")
        assert resp.status_code == 200
        assert "Admin" in resp.text


# ── Auth Session Helpers ───────────────────────────────────────


class TestAuthSession:
    async def test_save_and_load_session(self):
        mock_redis = AsyncMock()
        store: dict[str, str] = {}

        async def mock_set(key: str, value: str, ttl: int = 0) -> bool:
            store[key] = value
            return True

        async def mock_get(key: str) -> str | None:
            return store.get(key)

        mock_redis.set = mock_set
        mock_redis.get = mock_get

        user = DashboardUser(
            name="Alice",
            email="alice@example.com",
            role=DashboardRole.ADMIN,
        )
        await AuthMiddleware.save_session(mock_redis, "sess-1", user)
        assert "session:sess-1" in store

        # Verify stored data.
        data = json.loads(store["session:sess-1"])
        assert data["name"] == "Alice"
        assert data["role"] == DashboardRole.ADMIN.value

    async def test_delete_session(self):
        mock_redis = AsyncMock()
        mock_redis.delete = AsyncMock(return_value=True)

        result = await AuthMiddleware.delete_session(mock_redis, "sess-1")
        assert result is True
        mock_redis.delete.assert_awaited_once_with("session:sess-1")

    def test_session_ttl_is_8_hours(self):
        assert SESSION_TTL == 8 * 3600


# ── Auth Routes ────────────────────────────────────────────────


class TestAuthRoutes:
    def test_callback_rejects_missing_state(self):
        _setup_app_state()
        entra = _make_entra()
        app.state.entra = entra
        app.state.auth_redis = AsyncMock()
        app.state.auth_redis.get = AsyncMock(return_value=None)

        for mw in app.user_middleware:
            if hasattr(mw, "kwargs"):
                mw.kwargs["entra"] = entra
                mw.kwargs["redis"] = app.state.auth_redis
        app.middleware_stack = app.build_middleware_stack()

        client = TestClient(app, raise_server_exceptions=False)

        resp = client.get("/auth/callback?code=test", follow_redirects=False)
        assert resp.status_code == 302
        assert "/login" in resp.headers["location"]

    def test_callback_rejects_error_from_entra(self):
        _setup_app_state()
        entra = _make_entra()
        app.state.entra = entra
        app.state.auth_redis = AsyncMock()
        app.state.auth_redis.get = AsyncMock(return_value=None)

        for mw in app.user_middleware:
            if hasattr(mw, "kwargs"):
                mw.kwargs["entra"] = entra
                mw.kwargs["redis"] = app.state.auth_redis
        app.middleware_stack = app.build_middleware_stack()

        client = TestClient(app, raise_server_exceptions=False)

        client.cookies.set("maude_auth_state", "abc")
        resp = client.get(
            "/auth/callback?error=access_denied&error_description=No+consent&state=abc",
        )
        assert resp.status_code == 200
        assert "No consent" in resp.text

    def test_nav_shows_logout_when_auth_enabled(self):
        _setup_app_state()
        entra = _make_entra()
        app.state.entra = entra

        mock_redis = AsyncMock()
        session_data = json.dumps(
            {
                "name": "Alice",
                "email": "w@c.com",
                "role": DashboardRole.ADMIN.value,
            }
        )
        mock_redis.get = AsyncMock(return_value=session_data)
        app.state.auth_redis = mock_redis

        for mw in app.user_middleware:
            if hasattr(mw, "kwargs"):
                mw.kwargs["entra"] = entra
                mw.kwargs["redis"] = mock_redis
        app.middleware_stack = app.build_middleware_stack()

        client = TestClient(app, raise_server_exceptions=True)
        client.cookies.set(SESSION_COOKIE, "valid")
        resp = client.get("/")
        assert resp.status_code == 200
        assert "/logout" in resp.text
        assert "Alice" in resp.text

    def test_nav_hides_logout_when_auth_disabled(self):
        _setup_app_state()
        app.state.entra = EntraAuth({})
        app.state.auth_redis = None
        client = TestClient(app, raise_server_exceptions=True)

        resp = client.get("/")
        assert resp.status_code == 200
        assert "/logout" not in resp.text
