# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""ConciergeLogger — async fire-and-forget conversation logger.

Writes concierge chat conversations to the ``agent_memory`` table
with ``memory_type='concierge'``, preserving routing metadata from
the agency system for downstream training export.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from maude.db import LazyPool

logger = logging.getLogger(__name__)

INSERT_SQL = """
    INSERT INTO agent_memory
        (project, memory_type, trigger, context, outcome,
         summary, tokens_used, model, conversation)
    VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, $9::jsonb)
"""


class ConciergeLogger:
    """Async fire-and-forget conversation logger.

    Writes completed chat conversations to ``agent_memory`` with
    routing metadata from the agency system. All errors are caught
    and logged — this never blocks the chat response.
    """

    def __init__(self, pool: LazyPool) -> None:
        self._pool = pool

    async def log(
        self,
        session_id: str,
        messages: list[dict[str, Any]],
        routing: dict[str, Any] | None = None,
        tokens_used: int = 0,
        model: str = "",
    ) -> None:
        """Write a conversation to agent_memory.

        Args:
            session_id: Chat session identifier.
            messages: Full ChatML-compatible message list.
            routing: Agency routing metadata (department, confidence, etc.).
            tokens_used: Cumulative token count from LLM calls.
            model: LLM model used for the response.
        """
        try:
            pool = await self._pool.get()
            if pool is None:
                return

            routing = routing or {}
            context = {
                "session_id": session_id,
                "department": routing.get("department"),
                "agent_name": routing.get("agent_name"),
                "routing_method": routing.get("routing_method"),
                "confidence": routing.get("confidence"),
                "also_relevant": routing.get("also_relevant", []),
            }

            # First user message as summary (truncated).
            summary = ""
            for msg in messages:
                if msg.get("role") == "user" and isinstance(msg.get("content"), str):
                    summary = msg["content"][:200]
                    break

            outcome = "agency_routed" if routing.get("department") else "completed"

            await pool.execute(
                INSERT_SQL,
                "maude",              # project
                "concierge",           # memory_type
                "web_chat",            # trigger
                json.dumps(context),   # context
                outcome,               # outcome
                summary,               # summary
                tokens_used,           # tokens_used
                model,                 # model
                json.dumps(messages),  # conversation
            )
        except Exception:
            logger.warning("ConciergeLogger: failed to log conversation", exc_info=True)
