# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Authentication routes — login, callback, logout.

Supports two auth providers:
  - EntraAuth (MSAL-based, Microsoft Entra ID)
  - OIDCClient (generic OIDC, e.g. Authentik)

The active provider is determined by app.state.auth_provider ("entra" or "oidc").
"""

from __future__ import annotations

import inspect
import logging
import secrets
from typing import TYPE_CHECKING

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse

from maude.coordination.web.auth.middleware import SESSION_COOKIE, AuthMiddleware
from maude.coordination.web.auth.roles import DashboardRole, DashboardUser

if TYPE_CHECKING:
    from maude.infra.redis_client import MaudeRedis

logger = logging.getLogger(__name__)
router = APIRouter()


def _get_auth(request: Request):
    """Return the active auth provider (EntraAuth or OIDCClient)."""
    provider = getattr(request.app.state, "auth_provider", "entra")
    if provider == "oidc":
        return request.app.state.oidc
    return request.app.state.entra


@router.get("/login", response_model=None)
async def login(request: Request) -> HTMLResponse | RedirectResponse:
    """Login page — redirects to identity provider or shows disabled message."""
    auth = _get_auth(request)
    if not auth.enabled:
        return RedirectResponse(url="/", status_code=302)

    # Generate CSRF state token and store in cookie.
    state = secrets.token_urlsafe(32)
    auth_url = auth.get_auth_url(state=state)
    # OIDCClient.get_auth_url is async; EntraAuth's is sync.
    if inspect.isawaitable(auth_url):
        auth_url = await auth_url

    if not auth_url:
        templates = request.app.state.templates
        return templates.TemplateResponse(request, "auth/login.html", {
            "error": "Authentication service unavailable.",
        })

    response = RedirectResponse(url=auth_url, status_code=302)
    response.set_cookie(
        "maude_auth_state", state,
        max_age=600, httponly=True, samesite="lax",
    )
    return response


@router.get("/auth/callback", response_model=None)
async def auth_callback(request: Request) -> RedirectResponse | HTMLResponse:
    """OAuth2 callback — exchange code for session."""
    auth = _get_auth(request)
    redis: MaudeRedis | None = request.app.state.auth_redis

    if not auth.enabled or not redis:
        return RedirectResponse(url="/", status_code=302)

    # Verify CSRF state.
    state = request.query_params.get("state", "")
    expected_state = request.cookies.get("maude_auth_state", "")
    if not state or state != expected_state:
        logger.warning("Auth callback: CSRF state mismatch")
        return RedirectResponse(url="/login", status_code=302)

    # Check for error from identity provider.
    error = request.query_params.get("error", "")
    if error:
        logger.warning("Auth callback: IdP error: %s", error)
        templates = request.app.state.templates
        return templates.TemplateResponse(request, "auth/login.html", {
            "error": f"Login failed: {request.query_params.get('error_description', error)}",
        })

    # Exchange authorization code for user info.
    code = request.query_params.get("code", "")
    if not code:
        return RedirectResponse(url="/login", status_code=302)

    user_info = await auth.exchange_code(code)
    if not user_info:
        templates = request.app.state.templates
        return templates.TemplateResponse(request, "auth/login.html", {
            "error": "Failed to complete authentication. Please try again.",
        })

    # Resolve role from group memberships.
    role_name = auth.resolve_role(user_info.get("groups", []))
    role = DashboardRole[role_name.upper()]
    user = DashboardUser(
        name=user_info["name"],
        email=user_info["email"],
        role=role,
    )

    # Create session in Redis.
    session_id = secrets.token_urlsafe(32)
    await AuthMiddleware.save_session(redis, session_id, user)

    response = RedirectResponse(url="/", status_code=302)
    response.set_cookie(
        SESSION_COOKIE, session_id,
        max_age=8 * 3600, httponly=True, samesite="lax",
    )
    response.delete_cookie("maude_auth_state")
    logger.info("Auth: %s (%s) logged in as %s", user.name, user.email, role_name)
    return response


@router.get("/logout")
async def logout(request: Request) -> RedirectResponse:
    """Logout — clear session cookie and Redis session."""
    redis: MaudeRedis | None = request.app.state.auth_redis
    session_id = request.cookies.get(SESSION_COOKIE, "")

    if session_id and redis:
        await AuthMiddleware.delete_session(redis, session_id)

    response = RedirectResponse(url="/login", status_code=302)
    response.delete_cookie(SESSION_COOKIE)
    return response
