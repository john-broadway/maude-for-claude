# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for the updated search route — two-panel results."""
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from maude.coordination.web.app import TEMPLATE_DIR, _state, app
from maude.coordination.web.auth.entra import EntraAuth
from maude.coordination.web.chat import ChatSessionStore
from maude.coordination.web.services.document_search import DocumentSearch
from maude.coordination.web.state import AppState


@pytest.fixture
def mock_agency_router():
    router = AsyncMock()
    router.route_and_ask.return_value = {
        "department": "hp/quality",
        "agent_name": "Quality Agent",
        "answer": "Industrial process follows ASTM B689.",
        "also_relevant": [
            {"department": "hp/engineering", "agent_name": "Engineering", "score": 0.6}
        ],
        "routing": [
            {"department": "hp/quality", "combined_score": 0.85},
            {"department": "hp/engineering", "combined_score": 0.6},
        ],
        "confidence": 0.85,
    }
    return router


@pytest.fixture
def mock_doc_search():
    search = AsyncMock(spec=DocumentSearch)
    search.search.return_value = [
        {
            "filename": "spec-sheet.pdf",
            "path": "/Quality/spec-sheet.pdf",
            "site": "site-a",
            "share": "Quality",
            "file_type": "pdf",
            "extension": ".pdf",
            "score": 0.92,
            "preview": "Industrial process specification...",
            "itar_flag": False,
            "source": "unas",
            "parent_doctype": "",
            "parent_name": "",
        }
    ]
    return search


@pytest.fixture(autouse=True)
def mock_state(mock_agency_router, mock_doc_search):
    """Set up mock state — follows test_web_app.py pattern."""
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()

    mock_llm = AsyncMock()
    mock_llm.close = AsyncMock()

    chat_store = ChatSessionStore()

    _state.update({
        "memory": mock_memory,
        "deps": MagicMock(),
        "briefing": MagicMock(),
        "chat_llm": mock_llm,
        "chat_store": chat_store,
        "chat_agent": MagicMock(),
        "agents": {},
        "fleet": MagicMock(),
        "agency_router": mock_agency_router,
        "document_search": mock_doc_search,
    })

    app.state.dashboard = AppState(
        memory=mock_memory,
        deps=MagicMock(),
        briefing=MagicMock(),
        chat_llm=mock_llm,
        chat_store=chat_store,
        chat_agent=MagicMock(),
        agents={},
        fleet=MagicMock(),
        agency_router=mock_agency_router,
        document_search=mock_doc_search,
    )
    app.state.templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
    app.state.entra = EntraAuth({})
    app.state.auth_redis = None

    yield

    _state.clear()


@pytest.fixture
def client():
    return TestClient(app, raise_server_exceptions=True)


class TestSearchPage:
    def test_search_page_loads(self, client):
        resp = client.get("/search")
        assert resp.status_code == 200
        assert "Agency Search" in resp.text

    def test_home_page_has_search_bar(self, client):
        resp = client.get("/")
        assert resp.status_code == 200
        assert "How may I help you?" in resp.text


class TestApiSearch:
    def test_two_panel_results(self, client, mock_agency_router, mock_doc_search):
        resp = client.post(
            "/api/search",
            data={"question": "industrial process spec"},
        )
        assert resp.status_code == 200
        # Department answer panel
        assert "hp/quality" in resp.text
        assert "ASTM B689" in resp.text
        # Document results panel
        assert "spec-sheet.pdf" in resp.text
        assert "Documents" in resp.text

    def test_search_calls_document_search(self, client, mock_doc_search):
        resp = client.post(
            "/api/search",
            data={"question": "defense specs"},
        )
        assert resp.status_code == 200
        mock_doc_search.search.assert_called_once()

    def test_empty_question_error(self, client):
        resp = client.post("/api/search", data={"question": ""})
        assert resp.status_code == 200
        assert "Please enter a question" in resp.text

    def test_chat_link_present(self, client):
        resp = client.post(
            "/api/search",
            data={"question": "quality standards"},
        )
        assert resp.status_code == 200
        assert "Continue in Chat" in resp.text
        assert "/chat?dept=" in resp.text

    def test_agency_failure_still_shows_docs(self, client, mock_agency_router, mock_doc_search):
        mock_agency_router.route_and_ask.side_effect = Exception("LLM down")
        resp = client.post(
            "/api/search",
            data={"question": "industrial process"},
        )
        assert resp.status_code == 200
        # Should still show document results
        assert "spec-sheet.pdf" in resp.text

    def test_no_doc_search_graceful(self, client, mock_agency_router):
        """When document_search is None, still returns agency results."""
        app.state.dashboard.document_search = None
        resp = client.post(
            "/api/search",
            data={"question": "quality standards"},
        )
        assert resp.status_code == 200
        assert "ASTM B689" in resp.text


class TestChatPage:
    def test_chat_page_loads(self, client):
        resp = client.get("/chat")
        assert resp.status_code == 200
        assert "Maude" in resp.text
        assert "chat-input" in resp.text

    def test_chat_with_dept(self, client):
        resp = client.get("/chat?dept=quality")
        assert resp.status_code == 200
        assert "quality" in resp.text

    def test_chat_with_context(self, client):
        resp = client.get("/chat?context=industrial+process+specs")
        assert resp.status_code == 200
        assert "industrial process specs" in resp.text
