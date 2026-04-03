# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Entra ID (Azure AD) authentication via MSAL.

Wraps MSAL's ConfidentialClientApplication for the OAuth2 auth code flow.
When credentials are not configured, all methods return None/empty — the
middleware falls back to anonymous access.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


class EntraAuth:
    """MSAL wrapper for Entra ID authentication."""

    def __init__(self, config: dict[str, Any]) -> None:
        self._tenant_id = config.get("tenant_id", "")
        self._client_id = config.get("client_id", "")
        self._client_secret = config.get("client_secret", "")
        self._redirect_uri = config.get("redirect_uri", "")
        self._group_mapping: dict[str, str] = config.get("group_mapping", {})
        self._app: Any = None

        if self.enabled:
            self._init_msal()

    @property
    def enabled(self) -> bool:
        """True if Entra ID credentials are configured."""
        return bool(self._tenant_id and self._client_id and self._client_secret)

    def _init_msal(self) -> None:
        """Initialize MSAL ConfidentialClientApplication."""
        try:
            import msal

            authority = f"https://login.microsoftonline.com/{self._tenant_id}"
            self._app = msal.ConfidentialClientApplication(
                client_id=self._client_id,
                client_credential=self._client_secret,
                authority=authority,
            )
            logger.info("EntraAuth: initialized (tenant=%s)", self._tenant_id)
        except Exception:
            logger.warning("EntraAuth: MSAL initialization failed", exc_info=True)
            self._app = None

    def get_auth_url(self, state: str = "") -> str | None:
        """Build the Microsoft login URL for the auth code flow.

        Args:
            state: Opaque value to prevent CSRF (passed through the flow).

        Returns:
            Authorization URL, or None if not configured.
        """
        if not self._app:
            return None
        try:
            result = self._app.get_authorization_request_url(
                scopes=["User.Read"],
                redirect_uri=self._redirect_uri,
                state=state,
            )
            return result
        except Exception:
            logger.warning("EntraAuth: failed to build auth URL", exc_info=True)
            return None

    async def exchange_code(self, code: str) -> dict[str, Any] | None:
        """Exchange authorization code for tokens and user info.

        Returns:
            Dict with "name", "email", "groups" on success, None on failure.
        """
        if not self._app:
            return None
        try:
            result = self._app.acquire_token_by_authorization_code(
                code=code,
                scopes=["User.Read"],
                redirect_uri=self._redirect_uri,
            )
            if "error" in result:
                logger.warning("EntraAuth: token exchange failed: %s", result.get("error"))
                return None

            id_claims = result.get("id_token_claims", {})
            return {
                "name": id_claims.get("name", id_claims.get("preferred_username", "Unknown")),
                "email": id_claims.get("preferred_username", ""),
                "groups": id_claims.get("groups", []),
            }
        except Exception:
            logger.warning("EntraAuth: code exchange failed", exc_info=True)
            return None

    def resolve_role(self, groups: list[str]) -> str:
        """Map Entra group IDs to a dashboard role name.

        Returns the highest-privilege role matched, or "viewer" if no match.
        """
        from maude.coordination.web.auth.roles import DashboardRole

        best = DashboardRole.VIEWER
        for group_id in groups:
            role_name = self._group_mapping.get(group_id, "")
            if role_name == "admin" and DashboardRole.ADMIN > best:
                best = DashboardRole.ADMIN
            elif role_name == "operator" and DashboardRole.OPERATOR > best:
                best = DashboardRole.OPERATOR
        return best.name.lower()
