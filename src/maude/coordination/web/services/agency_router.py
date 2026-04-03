# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""AgencyRouter — unified semantic + keyword routing for agency queries.

Eliminates duplication between ``app.py:api_search`` and
``chat.py:_execute_tool("agency_ask")``. Both now call this single
implementation.
"""

from __future__ import annotations

import logging
from typing import Any

from maude.coordination.agency import _chat, _keyword_scores
from maude.coordination.search import AGENTS_COLLECTION, _embed, _qdrant_search

logger = logging.getLogger(__name__)


class AgencyRouter:
    """Route questions to department agents via merged ranking."""

    def __init__(self, agents: dict[str, dict[str, Any]]) -> None:
        self._agents = agents

    @property
    def agents(self) -> dict[str, dict[str, Any]]:
        return self._agents

    async def route_and_ask(
        self,
        question: str,
        *,
        top_k: int = 5,
    ) -> dict[str, Any]:
        """Route a question and return the answer + routing metadata.

        Returns dict with keys:
            department, agent_name, answer, also_relevant, routing
        """
        # 1. Semantic search
        semantic_scores: dict[str, float] = {}
        try:
            embedding = await _embed(question)
            hits = await _qdrant_search(AGENTS_COLLECTION, embedding, top_k=top_k)
            for hit in hits:
                payload = hit.get("payload", {})
                dept = payload.get("department", "")
                score = hit.get("score", 0.0)
                if dept and dept not in semantic_scores:
                    semantic_scores[dept] = score
        except Exception:
            logger.warning("Semantic search failed in route_and_ask", exc_info=True)

        # 2. Keyword routing
        kw_results = _keyword_scores(question, self._agents)

        # 3. Merge & rank (0.7 semantic + 0.3 keyword)
        all_depts: set[str] = set(semantic_scores.keys())
        for r in kw_results:
            all_depts.add(r["department"])

        sem_max = max(semantic_scores.values()) if semantic_scores else 1.0
        kw_max = max(r["score"] for r in kw_results) if kw_results else 1.0
        kw_map = {r["department"]: r["score"] for r in kw_results}

        merged: list[dict[str, Any]] = []
        for dept in all_depts:
            sem_norm = (semantic_scores.get(dept, 0.0) / sem_max) if sem_max else 0.0
            kw_norm = (kw_map.get(dept, 0.0) / kw_max) if kw_max else 0.0
            combined = 0.7 * sem_norm + 0.3 * kw_norm
            merged.append(
                {
                    "department": dept,
                    "combined_score": round(combined, 4),
                }
            )

        merged.sort(key=lambda x: x["combined_score"], reverse=True)

        if not merged:
            return {
                "department": None,
                "agent_name": None,
                "answer": None,
                "also_relevant": [],
                "routing": [],
                "error": "No relevant department found.",
            }

        # 4. Query the top-ranked department
        top_dept = merged[0]["department"]
        info = self._agents.get(top_dept, {})
        model_name = f"{top_dept}-agent"
        answer = await _chat(model_name, question)

        also_relevant = [
            {
                "department": m["department"],
                "agent_name": self._agents.get(m["department"], {}).get("agent_name", "?"),
                "score": m["combined_score"],
            }
            for m in merged[1:4]
            if m["combined_score"] > 0.2
        ]

        return {
            "department": top_dept,
            "agent_name": info.get("agent_name", "?"),
            "answer": answer,
            "also_relevant": also_relevant,
            "routing": merged[:5],
            "confidence": merged[0]["combined_score"],
            "routing_method": "semantic+keyword",
        }

    def keyword_search(self, topic: str) -> list[dict[str, Any]]:
        """Keyword-only search for who_handles queries."""
        return _keyword_scores(topic, self._agents)
