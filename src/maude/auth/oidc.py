# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# ──────────────────────────────────────────────
# OIDCClient — Generic OIDC authentication client
# Version: 1.0.0
# Created: 2026-03-12 10:30 MST
# Author(s): John Broadway
# ──────────────────────────────────────────────
"""Generic OIDC authentication client.

Uses httpx for OIDC discovery and token exchange. Designed as a drop-in
alternative to EntraAuth for any OIDC-compliant identity provider
(Authentik, Keycloak, Okta, etc.).

Config dict keys:
    issuer          -- OIDC issuer URL (e.g. https://localhost:9443/application/o/app-slug/)
    client_id       -- OAuth2 client ID
    client_secret   -- OAuth2 client secret
    redirect_uri    -- Default redirect URI for callbacks
    scopes          -- Space-separated scopes (default: "openid profile email")
    group_claim     -- Claim name for group membership (default: "groups")
    group_mapping   -- Dict mapping group name → role name ("admin", "operator")
    verify_ssl      -- Whether to verify TLS certificates (default: True)
"""

from __future__ import annotations

import logging
from typing import Any
from urllib.parse import urlencode

import httpx

logger = logging.getLogger(__name__)


class OIDCClient:
    """Generic OIDC client using the authorization code flow."""

    def __init__(self, config: dict[str, Any]) -> None:
        self._issuer = config.get("issuer", "").rstrip("/")
        self._client_id = config.get("client_id", "")
        self._client_secret = config.get("client_secret", "")
        self._redirect_uri = config.get("redirect_uri", "")
        self._scopes = config.get("scopes", "openid profile email")
        self._group_mapping: dict[str, str] = config.get("group_mapping", {})
        self._group_claim: str = config.get("group_claim", "groups")
        self._verify_ssl: bool = config.get("verify_ssl", True)

        # Cached OIDC discovery endpoints.
        self._authorization_endpoint: str = ""
        self._token_endpoint: str = ""
        self._userinfo_endpoint: str = ""
        self._discovery_loaded = False

        if self.enabled:
            logger.info("OIDCClient: configured (issuer=%s)", self._issuer)

    @property
    def enabled(self) -> bool:
        """True if OIDC credentials are configured."""
        return bool(self._issuer and self._client_id and self._client_secret)

    async def _ensure_discovery(self) -> bool:
        """Fetch and cache OIDC discovery document."""
        if self._discovery_loaded:
            return True

        url = f"{self._issuer}/.well-known/openid-configuration"
        try:
            async with httpx.AsyncClient(verify=self._verify_ssl) as client:
                resp = await client.get(url, timeout=10)
                resp.raise_for_status()
                doc = resp.json()

            self._authorization_endpoint = doc["authorization_endpoint"]
            self._token_endpoint = doc["token_endpoint"]
            self._userinfo_endpoint = doc.get("userinfo_endpoint", "")
            self._discovery_loaded = True
            logger.info("OIDCClient: discovery loaded from %s", url)
            return True
        except Exception:
            logger.warning("OIDCClient: discovery failed from %s", url, exc_info=True)
            return False

    async def get_auth_url(self, state: str = "", redirect_uri: str = "") -> str | None:
        """Build the authorization URL for the OIDC auth code flow.

        Args:
            state: Opaque CSRF prevention value.
            redirect_uri: Override the configured redirect URI.

        Returns:
            Authorization URL, or None if not configured / discovery failed.
        """
        if not self.enabled:
            return None

        if not await self._ensure_discovery():
            return None

        params = {
            "response_type": "code",
            "client_id": self._client_id,
            "redirect_uri": redirect_uri or self._redirect_uri,
            "scope": self._scopes,
            "state": state,
        }
        return f"{self._authorization_endpoint}?{urlencode(params)}"

    async def exchange_code(
        self,
        code: str,
        redirect_uri: str = "",
    ) -> dict[str, Any] | None:
        """Exchange authorization code for user info.

        Returns:
            Dict with "name", "email", "groups" on success, None on failure.
        """
        if not self.enabled:
            return None

        if not await self._ensure_discovery():
            return None

        try:
            async with httpx.AsyncClient(verify=self._verify_ssl) as client:
                # Exchange code for tokens.
                token_resp = await client.post(
                    self._token_endpoint,
                    data={
                        "grant_type": "authorization_code",
                        "code": code,
                        "redirect_uri": redirect_uri or self._redirect_uri,
                        "client_id": self._client_id,
                        "client_secret": self._client_secret,
                    },
                    timeout=10,
                )
                token_resp.raise_for_status()
                tokens = token_resp.json()

                if "error" in tokens:
                    logger.warning(
                        "OIDCClient: token exchange error: %s",
                        tokens["error"],
                    )
                    return None

                # Fetch user info with the access token.
                access_token = tokens.get("access_token", "")
                if not access_token or not self._userinfo_endpoint:
                    logger.warning("OIDCClient: missing access_token or userinfo_endpoint")
                    return None

                info_resp = await client.get(
                    self._userinfo_endpoint,
                    headers={"Authorization": f"Bearer {access_token}"},
                    timeout=10,
                )
                info_resp.raise_for_status()
                user_info = info_resp.json()

            return {
                "name": user_info.get("name", user_info.get("preferred_username", "Unknown")),
                "email": user_info.get("email", user_info.get("preferred_username", "")),
                "groups": user_info.get(self._group_claim, []),
            }
        except Exception:
            logger.warning("OIDCClient: code exchange failed", exc_info=True)
            return None

    def resolve_role(self, groups: list[str]) -> str:
        """Map OIDC group names to a role name.

        Checks each group against group_mapping and returns the
        highest-privilege role matched, or "viewer" if no match.

        This method is intentionally generic — it returns a string
        ("admin", "operator", "viewer") that the consuming app
        converts to its own role enum.
        """
        best = 0  # 0=viewer, 1=operator, 2=admin
        role_priority = {"admin": 2, "operator": 1, "viewer": 0}

        for group in groups:
            role_name = self._group_mapping.get(group, "")
            priority = role_priority.get(role_name, 0)
            if priority > best:
                best = priority

        priority_to_name = {2: "admin", 1: "operator", 0: "viewer"}
        return priority_to_name[best]
