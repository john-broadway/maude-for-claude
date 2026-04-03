# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Document search service — searches indexed documents in Qdrant.

Wraps Qdrant vector search with ITAR filtering and result formatting.
Used by the search route for the two-panel results layout.
"""

from __future__ import annotations

import logging
from typing import Any

from qdrant_client import AsyncQdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchValue

from maude.coordination.search import _embed_documents

logger = logging.getLogger(__name__)

# Qdrant collection for indexed documents
MINT_COLLECTION = "file_migration"

CONTENT_PREVIEW_LEN = 300


class DocumentSearch:
    """Search indexed documents in Qdrant with ITAR filtering."""

    def __init__(self, qdrant_client: AsyncQdrantClient) -> None:
        self._qdrant = qdrant_client

    async def search(
        self,
        query: str,
        top_k: int = 5,
        *,
        itar_cleared: bool = False,
    ) -> list[dict[str, Any]]:
        """Search documents. Filters ITAR unless caller is cleared."""
        try:
            embedding = await _embed_documents(query)
        except Exception:
            logger.warning("Embedding failed for document search", exc_info=True)
            return []

        # Build Qdrant filter
        must_conditions = []
        if not itar_cleared:
            must_conditions.append(FieldCondition(key="itar_flag", match=MatchValue(value=False)))

        query_filter = Filter(must=must_conditions) if must_conditions else None

        try:
            result = await self._qdrant.query_points(
                collection_name=MINT_COLLECTION,
                query=embedding,
                query_filter=query_filter,
                limit=top_k,
            )
        except Exception:
            logger.warning("Qdrant search failed for %s", MINT_COLLECTION, exc_info=True)
            return []

        return self._format_results(result.points)

    def _format_results(self, points: list) -> list[dict[str, Any]]:
        """Format Qdrant search results for template rendering."""
        results = []
        for hit in points:
            payload = hit.payload or {}
            results.append(
                {
                    "filename": payload.get("filename", payload.get("file_name", "Unknown")),
                    "path": payload.get("path", payload.get("source_path", "")),
                    "site": payload.get("site", payload.get("site_routing", "")),
                    "share": payload.get("share", payload.get("share_routing", "")),
                    "file_type": payload.get("file_type", ""),
                    "extension": payload.get("extension", payload.get("file_ext", "")),
                    "score": round(hit.score, 4),
                    "preview": payload.get(
                        "content_preview",
                        payload.get("extracted_text", ""),
                    )[:CONTENT_PREVIEW_LEN],
                    "itar_flag": payload.get("itar_flag", False),
                    "source": payload.get("source", "unas"),
                    "parent_doctype": payload.get("parent_doctype", ""),
                    "parent_name": payload.get("parent_name", ""),
                }
            )
        return results
