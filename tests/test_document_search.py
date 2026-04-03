# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for DocumentSearch service."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination.web.services.document_search import DocumentSearch


@pytest.fixture
def mock_qdrant():
    """Mock Qdrant client."""
    client = AsyncMock()
    return client


@pytest.fixture
def doc_search(mock_qdrant):
    return DocumentSearch(mock_qdrant)


def _make_point(score, payload):
    """Create a mock Qdrant ScoredPoint."""
    point = MagicMock()
    point.score = score
    point.payload = payload
    return point


class TestDocumentSearch:
    @pytest.mark.asyncio
    async def test_search_returns_formatted_results(self, doc_search, mock_qdrant):
        points = [
            _make_point(
                0.92,
                {
                    "filename": "spec-sheet.pdf",
                    "path": "/Quality/spec-sheet.pdf",
                    "site_routing": "site-a",
                    "share_routing": "Quality",
                    "file_ext": ".pdf",
                    "itar_flag": False,
                    "extracted_text": "Industrial process specification...",
                },
            ),
            _make_point(
                0.85,
                {
                    "filename": "drawing.stp",
                    "path": "/Engineering/drawing.stp",
                    "site_routing": "site-a",
                    "share_routing": "Engineering",
                    "file_ext": ".stp",
                    "itar_flag": False,
                },
            ),
        ]
        mock_result = MagicMock()
        mock_result.points = points
        mock_qdrant.query_points.return_value = mock_result

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            results = await doc_search.search("industrial process spec")

        assert len(results) == 2
        assert results[0]["filename"] == "spec-sheet.pdf"
        assert results[0]["score"] == 0.92
        assert results[0]["site"] == "site-a"
        assert results[0]["itar_flag"] is False

    @pytest.mark.asyncio
    async def test_itar_filtered_by_default(self, doc_search, mock_qdrant):
        mock_result = MagicMock()
        mock_result.points = []
        mock_qdrant.query_points.return_value = mock_result

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            await doc_search.search("defense article")

        # Check the filter was applied
        call_kwargs = mock_qdrant.query_points.call_args.kwargs
        assert call_kwargs.get("query_filter") is not None
        filter_obj = call_kwargs["query_filter"]
        assert len(filter_obj.must) == 1
        assert filter_obj.must[0].key == "itar_flag"

    @pytest.mark.asyncio
    async def test_itar_not_filtered_when_cleared(self, doc_search, mock_qdrant):
        mock_result = MagicMock()
        mock_result.points = []
        mock_qdrant.query_points.return_value = mock_result

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            await doc_search.search("defense article", itar_cleared=True)

        call_kwargs = mock_qdrant.query_points.call_args.kwargs
        assert call_kwargs.get("query_filter") is None

    @pytest.mark.asyncio
    async def test_embedding_failure_returns_empty(self, doc_search):
        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            side_effect=RuntimeError("vLLM down"),
        ):
            results = await doc_search.search("anything")

        assert results == []

    @pytest.mark.asyncio
    async def test_qdrant_failure_returns_empty(self, doc_search, mock_qdrant):
        mock_qdrant.query_points.side_effect = Exception("Connection refused")

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            results = await doc_search.search("anything")

        assert results == []

    @pytest.mark.asyncio
    async def test_erp_service_source_metadata(self, doc_search, mock_qdrant):
        points = [
            _make_point(
                0.88,
                {
                    "filename": "purchase-spec.pdf",
                    "source": "erp_service",
                    "parent_doctype": "Purchase Order",
                    "parent_name": "PO-00123",
                    "itar_flag": False,
                },
            ),
        ]
        mock_result = MagicMock()
        mock_result.points = points
        mock_qdrant.query_points.return_value = mock_result

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            results = await doc_search.search("purchase order spec")

        assert results[0]["source"] == "erp_service"
        assert results[0]["parent_doctype"] == "Purchase Order"
        assert results[0]["parent_name"] == "PO-00123"

    @pytest.mark.asyncio
    async def test_empty_results(self, doc_search, mock_qdrant):
        mock_result = MagicMock()
        mock_result.points = []
        mock_qdrant.query_points.return_value = mock_result

        with patch(
            "maude.coordination.web.services.document_search._embed_documents",
            new_callable=AsyncMock,
            return_value=[0.1] * 1024,
        ):
            results = await doc_search.search("nonexistent thing")

        assert results == []
