# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Route modules for the Maude Dashboard."""

from fastapi import FastAPI

from maude.coordination.web.routes.auth import router as auth_router
from maude.coordination.web.routes.autonomy import router as autonomy_router
from maude.coordination.web.routes.chat_api import router as chat_router
from maude.coordination.web.routes.chat_page import router as chat_page_router
from maude.coordination.web.routes.deps_page import router as deps_router
from maude.coordination.web.routes.ecosystem import router as ecosystem_router
from maude.coordination.web.routes.governance import router as governance_router
from maude.coordination.web.routes.health import router as health_router
from maude.coordination.web.routes.home import router as home_router
from maude.coordination.web.routes.info import router as info_router
from maude.coordination.web.routes.lobby import router as lobby_router
from maude.coordination.web.routes.memory import router as memory_router
from maude.coordination.web.routes.postmortem import router as postmortem_router
from maude.coordination.web.routes.rooms import router as rooms_router
from maude.coordination.web.routes.search import router as search_router

try:
    from maude.coordination.web.routes.webhook import (  # pyright: ignore[reportMissingImports]
        router as webhook_router,
    )
except ImportError:
    webhook_router = None  # type: ignore[assignment]


def include_routers(app: FastAPI) -> None:
    """Register all route modules on the app."""
    app.include_router(auth_router)
    app.include_router(health_router)
    app.include_router(home_router)
    app.include_router(lobby_router)
    app.include_router(rooms_router)
    app.include_router(ecosystem_router)
    app.include_router(autonomy_router)
    app.include_router(deps_router)
    app.include_router(memory_router)
    app.include_router(chat_router)
    app.include_router(info_router)
    app.include_router(governance_router)
    app.include_router(postmortem_router)
    app.include_router(search_router)
    app.include_router(chat_page_router)
    if webhook_router is not None:
        app.include_router(webhook_router)
