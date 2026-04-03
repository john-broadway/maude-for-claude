# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Maude Coordination — FastAPI web dashboard.

Single-page-of-glass for the hotel. Uses HTMX for dynamic updates
without a JavaScript build step. Includes LLM-powered chat.

Run:
    uvicorn maude.coordination.web.app:app --host 0.0.0.0 --port 8800
"""

import asyncio
import logging
import os
import threading
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import yaml
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from maude.auth.oidc import OIDCClient
from maude.coordination.agency import _discover_agents
from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph
from maude.coordination.web.auth.entra import EntraAuth
from maude.coordination.web.auth.middleware import AuthMiddleware
from maude.coordination.web.chat import ChatAgent, ChatSessionStore, ConciergeLogger
from maude.coordination.web.routes import include_routers
from maude.coordination.web.services.agency_router import AgencyRouter
from maude.coordination.web.services.fleet import FleetService
from maude.coordination.web.state import AppState
from maude.daemon.common import load_credentials
from maude.llm.router import LLMRouter

logger = logging.getLogger(__name__)

TEMPLATE_DIR = Path(__file__).parent / "templates"
STATIC_DIR = Path(__file__).parent / "static"
CONFIG_PATH = Path(__file__).parent.parent / "config.yaml"

# Backward-compat: tests pre-populate this to skip real initialization.
_state: dict[str, Any] = {}


class _LazyInit:
    """Thread-safe proxy: creates the wrapped object on first attribute access.

    Allows expensive components (CrossRoomMemory, LLMRouter, AgencyRouter) to
    be deferred until first use rather than instantiated at server startup.
    """

    def __init__(self, factory: Any) -> None:
        object.__setattr__(self, "_factory", factory)
        object.__setattr__(self, "_obj", None)
        object.__setattr__(self, "_lock", threading.Lock())

    def _resolve(self) -> Any:
        obj = object.__getattribute__(self, "_obj")
        if obj is None:
            with object.__getattribute__(self, "_lock"):
                obj = object.__getattribute__(self, "_obj")
                if obj is None:
                    obj = object.__getattribute__(self, "_factory")()
                    object.__setattr__(self, "_obj", obj)
        return obj

    def __getattr__(self, name: str) -> Any:
        return getattr(self._resolve(), name)

    async def close(self) -> None:
        obj = object.__getattribute__(self, "_obj")
        if obj is not None:
            closer = getattr(obj, "close", None)
            if closer:
                result = closer()
                if asyncio.iscoroutine(result):
                    await result


def _load_config() -> dict[str, Any]:
    """Load full config from config.yaml."""
    try:
        return yaml.safe_load(CONFIG_PATH.read_text()) or {}
    except Exception:
        logger.warning("Could not load config from %s", CONFIG_PATH)
        return {}


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Initialize and tear down shared components."""
    # Skip real initialization if tests pre-populated _state.
    if "memory" not in _state:
        _init_production_state()

    # Ensure fleet/agency_router exist (tests may not set them).
    if "fleet" not in _state:
        _state["fleet"] = FleetService(_state["memory"], _state["deps"])
    if "agency_router" not in _state:
        _state["agency_router"] = AgencyRouter(_state.get("agents", {}))

    app.state.dashboard = AppState(
        memory=_state["memory"],
        deps=_state["deps"],
        briefing=_state["briefing"],
        chat_llm=_state["chat_llm"],
        chat_store=_state["chat_store"],
        chat_agent=_state["chat_agent"],
        agents=_state.get("agents", {}),
        fleet=_state["fleet"],
        agency_router=_state["agency_router"],
        document_search=_state.get("document_search"),
        concierge_logger=_state.get("concierge_logger"),
    )
    app.state.templates = Jinja2Templates(directory=str(TEMPLATE_DIR))

    # Auth state — available to routes even when auth is disabled.
    app.state.auth_provider = _state.get("auth_provider", "entra")
    app.state.entra = _state.get("entra", EntraAuth({}))
    app.state.oidc = _state.get("oidc", OIDCClient({}))
    app.state.auth_redis = _state.get("auth_redis")

    # Connect auth Redis if available.
    auth_redis = app.state.auth_redis
    if auth_redis:
        await auth_redis.connect()

    await _state["chat_store"].start_eviction_loop()
    logger.info("Maude Maude web dashboard starting")
    yield

    await _state["chat_store"].stop_eviction_loop()
    await _state["chat_llm"].close()
    if auth_redis:
        await auth_redis.close()
    if _state.get("memory"):
        await _state["memory"].close()
    logger.info("Maude Maude web dashboard stopped")


def _init_production_state() -> None:
    """Build real state objects for production.

    Heavy components (CrossRoomMemory, LLMRouter, agency discovery) are wrapped
    in _LazyInit proxies — they instantiate only on first attribute access rather
    than at server startup. This cuts startup memory when the dashboard is idle.
    """
    config = _load_config()
    deps = DependencyGraph()

    chat_cfg = config.get("chat", {})
    llm_cfg = chat_cfg.get("llm", {})
    try:
        creds = load_credentials()
    except Exception:
        creds = {}

    # Auth — provider selection from config, credentials from secrets.yaml.
    auth_provider = config.get("auth", {}).get("provider", "entra")
    entra_cfg = creds.get("entra", {})
    entra = EntraAuth(entra_cfg)
    oidc_cfg = creds.get("oidc", {})
    oidc = OIDCClient(oidc_cfg)

    # Redis — shared across auth sessions and chat persistence.
    auth_redis = None
    redis_cfg = config.get("redis", {})
    if redis_cfg.get("enabled") and redis_cfg.get("host"):
        from maude.infra.redis_client import MaudeRedis

        auth_redis = MaudeRedis(
            host=redis_cfg["host"],
            port=redis_cfg.get("port", 6379),
            db=redis_cfg.get("db", 0),
            prefix="web",
        )

    # Chat session store — with optional Redis persistence.
    session_cfg = chat_cfg.get("session_persistence", {})
    chat_redis = auth_redis if session_cfg.get("enabled", True) else None
    chat_store = ChatSessionStore(
        ttl_minutes=chat_cfg.get("session_ttl_minutes", 30),
        max_sessions=20,
        max_messages=chat_cfg.get("max_session_messages", 20),
        redis=chat_redis,
    )

    # Concierge logger — writes conversations to agent_memory.
    concierge_logger = None
    logging_cfg = chat_cfg.get("logging", {})
    if logging_cfg.get("enabled", True):
        from maude.db import LazyPool

        concierge_logger = ConciergeLogger(
            LazyPool(database="agent", min_size=1, max_size=2),
        )

    # Heavy components — lazy proxies, instantiate on first access.
    memory: Any = _LazyInit(CrossRoomMemory)
    briefing = BriefingGenerator(memory, deps)

    _llm_cfg = llm_cfg
    _creds = creds
    chat_llm: Any = _LazyInit(lambda: LLMRouter.from_config(_llm_cfg, credentials=_creds))

    agency_root = Path(os.environ.get("AGENCY_ROOT", "/app/agency"))
    agency_router: Any = _LazyInit(lambda: AgencyRouter(_discover_agents(agency_root)))

    fleet = FleetService(memory, deps)
    chat_agent = ChatAgent(
        llm=chat_llm,
        memory=memory,
        deps=deps,
        briefing=briefing,
        max_iterations=chat_cfg.get("max_iterations", 5),
        agency_router=agency_router,
        concierge_logger=concierge_logger,
    )

    # Document search — uses same Qdrant client as search.py
    from maude.coordination.search import _get_qdrant_client
    from maude.coordination.web.services.document_search import DocumentSearch

    document_search = DocumentSearch(_get_qdrant_client())

    _state.update(
        {
            "memory": memory,
            "deps": deps,
            "briefing": briefing,
            "chat_llm": chat_llm,
            "chat_store": chat_store,
            "chat_agent": chat_agent,
            "agents": {},
            "fleet": fleet,
            "agency_router": agency_router,
            "document_search": document_search,
            "auth_provider": auth_provider,
            "entra": entra,
            "oidc": oidc,
            "auth_redis": auth_redis,
            "concierge_logger": concierge_logger,
        }
    )


def _create_app() -> FastAPI:
    """Build the FastAPI application with middleware."""
    application = FastAPI(
        title="Maude Coordinator",
        description="System-wide dashboard for Maude Rooms",
        lifespan=lifespan,
    )
    application.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
    include_routers(application)

    # Auth middleware — wraps all routes. When no auth provider is configured,
    # middleware injects ANONYMOUS_USER (admin) on every request.
    # Pass the active provider — middleware only uses .enabled property.
    auth_provider_name = _state.get("auth_provider", "entra")
    if auth_provider_name == "oidc":
        active_auth = _state.get("oidc", OIDCClient({}))
    else:
        active_auth = _state.get("entra", EntraAuth({}))
    auth_redis = _state.get("auth_redis")
    application.add_middleware(
        AuthMiddleware,
        entra=active_auth,
        redis=auth_redis,
    )

    return application


app = _create_app()
