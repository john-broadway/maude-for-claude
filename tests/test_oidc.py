# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# ──────────────────────────────────────────────
# Tests for OIDCClient
# Version: 1.0.0
# Created: 2026-03-12 10:45 MST
# Author(s): John Broadway
# ──────────────────────────────────────────────
"""Tests for OIDCClient — generic OIDC authentication client."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import httpx

from maude.auth.oidc import OIDCClient

# ── Discovery fixture ─────────────────────────────────────────

DISCOVERY_DOC = {
    "authorization_endpoint": "https://auth.example.com/authorize",
    "token_endpoint": "https://auth.example.com/token",
    "userinfo_endpoint": "https://auth.example.com/userinfo",
}

FULL_CONFIG = {
    "issuer": "https://auth.example.com",
    "client_id": "test-client-id",
    "client_secret": "test-client-secret",
    "redirect_uri": "http://localhost/callback",
    "scopes": "openid profile email",
    "group_mapping": {
        "admins": "admin",
        "operators": "operator",
    },
}


def _mock_discovery_response() -> MagicMock:
    """Build a mock httpx response for the discovery endpoint."""
    resp = MagicMock(spec=httpx.Response)
    resp.json.return_value = DISCOVERY_DOC
    resp.raise_for_status = MagicMock()
    return resp


def _mock_token_response(
    access_token: str = "tok-abc",
    error: str | None = None,
    include_access_token: bool = True,
) -> MagicMock:
    """Build a mock httpx response for the token endpoint."""
    resp = MagicMock(spec=httpx.Response)
    body: dict = {}
    if error:
        body["error"] = error
    elif include_access_token:
        body["access_token"] = access_token
    resp.json.return_value = body
    resp.raise_for_status = MagicMock()
    return resp


def _mock_userinfo_response(
    name: str = "Test User",
    email: str = "user@example.com",
    groups: list[str] | None = None,
    group_claim: str = "groups",
) -> MagicMock:
    """Build a mock httpx response for the userinfo endpoint."""
    resp = MagicMock(spec=httpx.Response)
    body = {"name": name, "email": email, group_claim: groups or []}
    resp.json.return_value = body
    resp.raise_for_status = MagicMock()
    return resp


# ── TestOIDCClient ────────────────────────────────────────────


class TestOIDCClient:
    def test_disabled_when_no_config(self):
        client = OIDCClient({})
        assert client.enabled is False

    def test_disabled_when_partial_config(self):
        client = OIDCClient({"issuer": "https://auth.example.com", "client_id": "abc"})
        assert client.enabled is False

    def test_enabled_when_fully_configured(self):
        client = OIDCClient(FULL_CONFIG)
        assert client.enabled is True

    async def test_get_auth_url_returns_none_when_disabled(self):
        client = OIDCClient({})
        result = await client.get_auth_url(state="test")
        assert result is None

    async def test_exchange_code_returns_none_when_disabled(self):
        client = OIDCClient({})
        result = await client.exchange_code("fake-code")
        assert result is None

    def test_resolve_role_default_viewer(self):
        client = OIDCClient({})
        assert client.resolve_role([]) == "viewer"

    def test_resolve_role_maps_groups(self):
        client = OIDCClient(FULL_CONFIG)
        assert client.resolve_role(["admins"]) == "admin"
        assert client.resolve_role(["operators"]) == "operator"
        assert client.resolve_role(["unknown-group"]) == "viewer"

    def test_resolve_role_picks_highest(self):
        client = OIDCClient(FULL_CONFIG)
        assert client.resolve_role(["operators", "admins"]) == "admin"

    async def test_get_auth_url_builds_correct_url(self):
        client = OIDCClient(FULL_CONFIG)

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.get = AsyncMock(return_value=_mock_discovery_response())
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            url = await client.get_auth_url(state="csrf-token")

        assert url is not None
        assert url.startswith("https://auth.example.com/authorize?")
        assert "response_type=code" in url
        assert "client_id=test-client-id" in url
        assert "state=csrf-token" in url

    async def test_get_auth_url_caches_discovery(self):
        client = OIDCClient(FULL_CONFIG)

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.get = AsyncMock(return_value=_mock_discovery_response())
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            url1 = await client.get_auth_url(state="s1")
            url2 = await client.get_auth_url(state="s2")

        assert url1 is not None
        assert url2 is not None
        # Discovery GET called once — second call uses cache.
        mock_http.get.assert_awaited_once()

    async def test_get_auth_url_returns_none_on_discovery_failure(self):
        client = OIDCClient(FULL_CONFIG)

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.get = AsyncMock(side_effect=httpx.ConnectError("connection refused"))
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            url = await client.get_auth_url(state="test")

        assert url is None

    async def test_exchange_code_returns_user_info(self):
        client = OIDCClient(FULL_CONFIG)
        client._authorization_endpoint = DISCOVERY_DOC["authorization_endpoint"]
        client._token_endpoint = DISCOVERY_DOC["token_endpoint"]
        client._userinfo_endpoint = DISCOVERY_DOC["userinfo_endpoint"]
        client._discovery_loaded = True

        token_resp = _mock_token_response(access_token="tok-xyz")
        userinfo_resp = _mock_userinfo_response(
            name="Alice",
            email="alice@example.com",
            groups=["admins", "operators"],
        )

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.post = AsyncMock(return_value=token_resp)
        mock_http.get = AsyncMock(return_value=userinfo_resp)
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            result = await client.exchange_code("auth-code-123")

        assert result is not None
        assert result["name"] == "Alice"
        assert result["email"] == "alice@example.com"
        assert result["groups"] == ["admins", "operators"]

    async def test_exchange_code_returns_none_on_token_error(self):
        client = OIDCClient(FULL_CONFIG)
        client._token_endpoint = DISCOVERY_DOC["token_endpoint"]
        client._userinfo_endpoint = DISCOVERY_DOC["userinfo_endpoint"]
        client._discovery_loaded = True

        token_resp = _mock_token_response(error="invalid_grant")

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.post = AsyncMock(return_value=token_resp)
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            result = await client.exchange_code("bad-code")

        assert result is None

    async def test_exchange_code_returns_none_on_missing_access_token(self):
        client = OIDCClient(FULL_CONFIG)
        client._token_endpoint = DISCOVERY_DOC["token_endpoint"]
        client._userinfo_endpoint = DISCOVERY_DOC["userinfo_endpoint"]
        client._discovery_loaded = True

        token_resp = _mock_token_response(include_access_token=False)

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.post = AsyncMock(return_value=token_resp)
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            result = await client.exchange_code("code-no-token")

        assert result is None

    async def test_exchange_code_custom_group_claim(self):
        config = {**FULL_CONFIG, "group_claim": "roles"}
        client = OIDCClient(config)
        client._token_endpoint = DISCOVERY_DOC["token_endpoint"]
        client._userinfo_endpoint = DISCOVERY_DOC["userinfo_endpoint"]
        client._discovery_loaded = True

        token_resp = _mock_token_response(access_token="tok-roles")
        userinfo_resp = _mock_userinfo_response(
            name="Concierge",
            email="concierge@example.com",
            groups=["role-admin"],
            group_claim="roles",
        )

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.post = AsyncMock(return_value=token_resp)
        mock_http.get = AsyncMock(return_value=userinfo_resp)
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            result = await client.exchange_code("code-roles")

        assert result is not None
        assert result["groups"] == ["role-admin"]

    async def test_redirect_uri_override(self):
        client = OIDCClient(FULL_CONFIG)

        mock_http = AsyncMock(spec=httpx.AsyncClient)
        mock_http.get = AsyncMock(return_value=_mock_discovery_response())
        mock_http.__aenter__ = AsyncMock(return_value=mock_http)
        mock_http.__aexit__ = AsyncMock(return_value=False)

        override_uri = "https://custom.example.com/oidc/callback"

        with patch("maude.auth.oidc.httpx.AsyncClient", return_value=mock_http):
            url = await client.get_auth_url(state="s", redirect_uri=override_uri)

        assert url is not None
        assert "custom.example.com" in url
        assert "localhost" not in url
