# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Search tools — semantic search over agent knowledge and document vectors.

Self-contained: calls Qdrant (vector search) and vLLM (embeddings) directly.
No dependency on the RAG API service.
"""

import logging
import os
from typing import Any

import httpx
from qdrant_client import AsyncQdrantClient

from maude.daemon.common import resolve_infra_hosts
from maude.daemon.guards import audit_logged
from maude.db import format_json as _format
from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)

EMBED_MODEL = "BAAI/bge-large-en-v1.5"
AGENTS_COLLECTION = "agents"
CONTENT_PREVIEW_LEN = 500

# BGE-large embedder service (1024d) on GPU machines (Active-Active)
_EMBEDDER_FALLBACK = "http://localhost:8000"

# Document collections indexed by the RAG pipeline
DOC_COLLECTIONS = [
    "documents",
    "hp_docs",
    "aim_docs",
    "sbm_docs",
    "do_docs",
]

SITE_COLLECTION_MAP = {
    "site-a": "hp_docs",
    "site-b": "hp_docs",
    "site-c": "site_c_docs",
    "site-d": "site_d_docs",
    "site-e": "site_e_docs",
}


_vllm_client: VLLMClient | None = None


def _get_vllm_client() -> VLLMClient:
    """Lazy-init module-level VLLMClient."""
    global _vllm_client
    if _vllm_client is None:
        _vllm_client = VLLMClient()
    return _vllm_client


_qdrant_client: AsyncQdrantClient | None = None


def _get_qdrant_client() -> AsyncQdrantClient:
    """Lazy-init module-level Qdrant client."""
    global _qdrant_client
    if _qdrant_client is None:
        infra = resolve_infra_hosts()
        host = infra.get("qdrant", "localhost")
        _qdrant_client = AsyncQdrantClient(host=host, port=6333, timeout=30)
    return _qdrant_client


async def _embed(text: str) -> list[float]:
    """Get 1024d embedding from vLLM (BGE-large) for agents collection."""
    client = _get_vllm_client()
    response = await client.embed(model=EMBED_MODEL, input=text)
    return list(response.embeddings[0])


def _get_embedder_urls() -> list[str]:
    """Resolve BGE-large embedder URLs for document collections (Active-Active)."""
    single = os.environ.get("MAUDE_EMBEDDER_URL", "")
    if single:
        return [single.rstrip("/")]
    infra = resolve_infra_hosts()
    hosts = infra.get("embedder_hosts", [])
    if hosts:
        return [f"http://{h}" if not h.startswith("http") else h for h in hosts]
    return [_EMBEDDER_FALLBACK]


async def _embed_documents(text: str) -> list[float]:
    """Get 1024d embedding from BGE-large embedder service for document collections.

    Tries each embedder host in order (Active-Active failover).
    """
    urls = _get_embedder_urls()
    last_err: Exception | None = None
    async with httpx.AsyncClient() as client:
        for url in urls:
            try:
                resp = await client.post(
                    f"{url}/embed",
                    json={"text": text},
                    timeout=60.0,
                )
                resp.raise_for_status()
                return resp.json()["embedding"]
            except Exception as e:
                logger.warning("Embedder %s failed: %s", url, e)
                last_err = e
    raise last_err or RuntimeError("No embedder hosts configured")


async def _qdrant_search(
    collection: str,
    vector: list[float],
    top_k: int = 5,
) -> list[dict]:
    """Search a Qdrant collection by vector."""
    try:
        client = _get_qdrant_client()
        result = await client.query_points(
            collection_name=collection,
            query=vector,
            limit=top_k,
        )
        return [{"score": hit.score, "payload": hit.payload or {}} for hit in result.points]
    except Exception:
        logger.warning("Qdrant search failed for %s", collection, exc_info=True)
        return []


# ── Tool registration ────────────────────────────────────────────────


def register_search_tools(mcp: Any, audit: Any) -> None:
    """Register semantic search tools on the MCP."""

    @mcp.tool()
    @audit_logged(audit)
    async def search_agents(query: str, top_k: int = 5) -> str:
        """Search department agent knowledge semantically.

        Searches the vector-indexed agent.md files for all Maude departments.
        Returns the most relevant sections from department agents matching
        the query (e.g., "who handles compliance?", "process qualification").

        Args:
            query: Natural language search query.
            top_k: Maximum results to return. Defaults to 5.

        Returns:
            JSON with ranked results including department, agent, section, and content.
        """
        try:
            embedding = await _embed(query)
        except Exception as e:
            return _format({"error": f"Embedding failed: {e}", "results": []})

        hits = await _qdrant_search(AGENTS_COLLECTION, embedding, top_k)

        results = []
        for hit in hits:
            payload = hit.get("payload", {})
            results.append(
                {
                    "department": payload.get("department", ""),
                    "agent_name": payload.get("agent_name", ""),
                    "section": payload.get("section", ""),
                    "score": round(hit.get("score", 0.0), 4),
                    "content": payload.get("content", "")[:CONTENT_PREVIEW_LEN],
                }
            )

        return _format(
            {
                "query": query,
                "count": len(results),
                "results": results,
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def search_documents(
        query: str,
        top_k: int = 5,
        site: str = "",
    ) -> str:
        """Search document vectors across Maude site collections.

        Searches indexed documents (specs, drawings, procedures, certs)
        stored in Qdrant. Optionally filter by site.

        Args:
            query: Natural language search query.
            top_k: Maximum results to return. Defaults to 5.
            site: Filter to a specific site (site-a, site-b, site-c, etc.).
                  Empty searches all collections.

        Returns:
            JSON with ranked document results including title, path, score.
        """
        try:
            embedding = await _embed_documents(query)
        except Exception as e:
            return _format({"error": f"Embedding failed: {e}", "results": []})

        # Determine which collections to search
        if site and site in SITE_COLLECTION_MAP:
            collections = [SITE_COLLECTION_MAP[site]]
        else:
            collections = DOC_COLLECTIONS

        all_hits: list[dict] = []
        for coll in collections:
            hits = await _qdrant_search(coll, embedding, top_k)
            for hit in hits:
                payload = hit.get("payload", {})
                all_hits.append(
                    {
                        "title": payload.get("filename", "Unknown"),
                        "path": payload.get("path", ""),
                        "site": payload.get("site", ""),
                        "collection": coll,
                        "score": round(hit.get("score", 0.0), 4),
                        "preview": payload.get("content_preview", "")[:CONTENT_PREVIEW_LEN],
                        "extension": payload.get("extension", ""),
                    }
                )

        # Sort by score, dedupe, limit
        all_hits.sort(key=lambda x: x["score"], reverse=True)
        seen: set[str] = set()
        deduped: list[dict] = []
        for h in all_hits:
            key = h["path"] or h["title"]
            if key not in seen:
                seen.add(key)
                deduped.append(h)

        return _format(
            {
                "query": query,
                "site_filter": site or "all",
                "collections_searched": collections,
                "count": len(deduped[:top_k]),
                "results": deduped[:top_k],
            }
        )
