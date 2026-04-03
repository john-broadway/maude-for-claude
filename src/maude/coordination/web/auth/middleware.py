# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Authentication middleware for the Maude Dashboard.

When an auth provider (Entra ID or OIDC) is configured, validates session
cookies against Redis. When no provider is configured, all requests get
ANONYMOUS_USER (admin).
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any, Protocol

from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import RedirectResponse, Response

from maude.coordination.web.auth.roles import ANONYMOUS_USER, DashboardRole, DashboardUser

if TYPE_CHECKING:
    from maude.infra.redis_client import MaudeRedis

logger = logging.getLogger(__name__)

# Routes that never require authentication.
PUBLIC_PATHS = frozenset({"/health", "/login", "/auth/callback"})
PUBLIC_PREFIXES = ("/static/",)

SESSION_COOKIE = "maude_session"
SESSION_TTL = 8 * 3600  # 8 hours


class AuthProvider(Protocol):
    """Minimal interface for an auth provider (EntraAuth or OIDCClient)."""

    @property
    def enabled(self) -> bool: ...


class AuthMiddleware(BaseHTTPMiddleware):
    """Validate session cookies and inject DashboardUser into request.state."""

    def __init__(
        self,
        app: Any,
        entra: AuthProvider,
        redis: MaudeRedis | None = None,
        admin_ips: list[str] | None = None,
    ) -> None:
        super().__init__(app)
        self._entra = entra
        self._redis = redis
        self._admin_ips = set(admin_ips or [])

    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint,
    ) -> Response:
        path = request.url.path

        # Public routes — no auth needed.
        if path in PUBLIC_PATHS or any(path.startswith(p) for p in PUBLIC_PREFIXES):
            request.state.user = ANONYMOUS_USER
            return await call_next(request)

        # Auth disabled — everyone is admin.
        if not self._entra.enabled:
            request.state.user = ANONYMOUS_USER
            return await call_next(request)

        # Emergency admin bypass via IP allowlist.
        client_ip = request.client.host if request.client else ""
        if client_ip and client_ip in self._admin_ips:
            request.state.user = DashboardUser(
                name=f"Admin ({client_ip})",
                email="",
                role=DashboardRole.ADMIN,
            )
            return await call_next(request)

        # Validate session cookie.
        session_id = request.cookies.get(SESSION_COOKIE, "")
        if session_id and self._redis:
            user = await self._load_session(session_id)
            if user:
                request.state.user = user
                return await call_next(request)

        # No valid session — redirect to login.
        return RedirectResponse(url="/login", status_code=302)

    async def _load_session(self, session_id: str) -> DashboardUser | None:
        """Load user from Redis session."""
        if not self._redis:
            return None
        try:
            data = await self._redis.get(f"session:{session_id}")
            if not data:
                return None
            session = json.loads(data)
            return DashboardUser(
                name=session["name"],
                email=session["email"],
                role=DashboardRole(session["role"]),
                session_id=session_id,
            )
        except Exception:
            logger.debug("Failed to load session %s", session_id[:8])
            return None

    @staticmethod
    async def save_session(
        redis: MaudeRedis,
        session_id: str,
        user: DashboardUser,
    ) -> bool:
        """Save a user session to Redis."""
        data = json.dumps({
            "name": user.name,
            "email": user.email,
            "role": user.role.value,
        })
        return await redis.set(f"session:{session_id}", data, ttl=SESSION_TTL)

    @staticmethod
    async def delete_session(redis: MaudeRedis, session_id: str) -> bool:
        """Delete a session from Redis."""
        return await redis.delete(f"session:{session_id}")
