# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""ChatAgent — LLM-powered concierge chat with tool dispatch.

Uses AgencyRouter for agency tools instead of reimplementing the
semantic+keyword routing locally.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncGenerator
from typing import TYPE_CHECKING, Any

from maude.coordination.web.chat.sessions import ChatSession
from maude.coordination.web.chat.tools import CHAT_TOOLS, SYSTEM_PROMPT

if TYPE_CHECKING:
    from maude.coordination.briefing import BriefingGenerator
    from maude.coordination.cross_room_memory import CrossRoomMemory
    from maude.coordination.dependencies import DependencyGraph
    from maude.coordination.web.chat.logger import ConciergeLogger
    from maude.coordination.web.services.agency_router import AgencyRouter
    from maude.llm.router import LLMRouter

logger = logging.getLogger(__name__)


class ChatAgent:
    """LLM-powered chat agent with read-only tool dispatch."""

    def __init__(
        self,
        llm: LLMRouter,
        memory: CrossRoomMemory,
        deps: DependencyGraph,
        briefing: BriefingGenerator,
        max_iterations: int = 5,
        agency_router: AgencyRouter | None = None,
        concierge_logger: ConciergeLogger | None = None,
    ) -> None:
        self._llm = llm
        self._memory = memory
        self._deps = deps
        self._briefing = briefing
        self._max_iterations = max_iterations
        self._agency_router = agency_router
        self._logger = concierge_logger

    async def respond(
        self,
        session: ChatSession,
        user_message: str,
    ) -> AsyncGenerator[str, None]:
        """Process a user message and yield SSE-formatted JSON strings.

        Yields JSON strings like:
            {"type": "text", "content": "..."}
            {"type": "tool_call", "name": "room_status"}
            {"type": "done"}
            {"type": "error", "content": "..."}
        """
        session.messages.append({"role": "user", "content": user_message})

        total_tokens = 0
        last_model = ""
        last_routing: dict[str, Any] = {}

        for _iteration in range(self._max_iterations):
            response = await self._llm.send(
                messages=session.messages,
                tools=CHAT_TOOLS,
                max_tokens=2048,
                system=SYSTEM_PROMPT,
            )

            if response is None:
                yield json.dumps({"type": "error", "content": "All LLM backends unavailable."})
                yield json.dumps({"type": "done"})
                self._fire_log(session, last_routing, total_tokens, last_model)
                return

            total_tokens += response.tokens_used or 0
            last_model = response.model or last_model

            if response.tool_calls:
                session.messages.append({
                    "role": "assistant",
                    "content": response.content,
                    "tool_calls": [
                        {"id": tc.id, "name": tc.name, "arguments": tc.arguments}
                        for tc in response.tool_calls
                    ],
                })

                for tc in response.tool_calls:
                    yield json.dumps({"type": "tool_call", "name": tc.name})
                    result = await self._execute_tool(tc.name, tc.arguments)
                    # Capture routing metadata from agency_ask calls.
                    if tc.name == "agency_ask" and self._last_routing:
                        last_routing = self._last_routing
                    session.messages.append({
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": tc.id,
                                "content": result,
                            }
                        ],
                    })
                continue

            if response.content:
                session.messages.append({
                    "role": "assistant",
                    "content": response.content,
                })
                yield json.dumps({"type": "text", "content": response.content})

            yield json.dumps({"type": "done"})
            self._fire_log(session, last_routing, total_tokens, last_model)
            return

        yield json.dumps({
            "type": "text",
            "content": (
                "I apologize — I was unable to complete"
                " your request within the allowed steps."
            ),
        })
        yield json.dumps({"type": "done"})
        self._fire_log(session, last_routing, total_tokens, last_model)

    def _fire_log(
        self,
        session: ChatSession,
        routing: dict[str, Any],
        tokens_used: int,
        model: str,
    ) -> None:
        """Fire async log task if logger is configured."""
        if not self._logger:
            return
        asyncio.create_task(self._logger.log(
            session_id=session.session_id,
            messages=session.messages.copy(),
            routing=routing,
            tokens_used=tokens_used,
            model=model,
        ))

    async def _execute_tool(self, name: str, args: dict[str, Any]) -> str:
        """Dispatch a tool call to the appropriate handler."""
        try:
            if name == "room_status":
                minutes = args.get("minutes", 60)
                return await self._briefing.room_status(minutes=minutes)

            elif name == "hotel_briefing":
                scope = args.get("scope", "all")
                minutes = args.get("minutes", 60)
                return await self._briefing.generate(scope=scope, minutes=minutes)

            elif name == "room_dependencies":
                room = args.get("room", "")
                if not room:
                    return "Error: room name is required."
                deps_on = self._deps.depends_on(room)
                dep_by = self._deps.depended_by(room)
                affected = self._deps.affected_by(room)
                lines = [f"Dependencies for {room}:"]
                lines.append(f"  Depends on: {', '.join(deps_on) if deps_on else 'none'}")
                lines.append(f"  Needed by: {', '.join(dep_by) if dep_by else 'none'}")
                if affected:
                    lines.append(f"  If {room} goes down, affected: {', '.join(affected)}")
                return "\n".join(lines)

            elif name == "recent_incidents":
                return await self._format_incidents(args.get("minutes", 60))

            elif name == "recent_escalations":
                return await self._format_escalations(args.get("minutes", 60))

            elif name == "recent_restarts":
                return await self._format_restarts(args.get("minutes", 60))

            elif name == "agency_ask":
                return await self._handle_agency_ask(args)

            elif name == "agency_who_handles":
                return self._handle_who_handles(args)

            elif name == "agency_list":
                return self._handle_agency_list()

            elif name == "search_agents":
                return await self._handle_search_agents(args)

            else:
                return f"Unknown tool: {name}"

        except Exception as exc:
            logger.warning("Chat tool %s failed: %s", name, exc)
            return f"Tool {name} encountered an error: {exc}"

    # ── Hotel tool formatters ──────────────────────────────────────

    async def _format_incidents(self, minutes: int) -> str:
        incidents = await self._memory.recent_incidents(minutes=minutes)
        if not incidents:
            return "No incidents in this time window."
        lines = [f"Recent incidents ({len(incidents)}) in last {minutes} min:"]
        for inc in incidents[:15]:
            ts = inc.get("created_at", "?")
            if isinstance(ts, str) and len(ts) > 16:
                ts = ts[:16]
            room = inc.get("project", "?")
            outcome = inc.get("outcome", "?")
            summary = (inc.get("summary") or "")[:100]
            lines.append(f"  [{ts}] {room}: {summary} [{outcome}]")
        return "\n".join(lines)

    async def _format_escalations(self, minutes: int) -> str:
        escalations = await self._memory.recent_escalations(minutes=minutes)
        if not escalations:
            return "No escalations in this time window."
        lines = [f"Escalations ({len(escalations)}) in last {minutes} min:"]
        for esc in escalations[:10]:
            ts = esc.get("created_at", "?")
            if isinstance(ts, str) and len(ts) > 16:
                ts = ts[:16]
            room = esc.get("project", "?")
            summary = (esc.get("summary") or "")[:100]
            lines.append(f"  [{ts}] {room}: {summary}")
        return "\n".join(lines)

    async def _format_restarts(self, minutes: int) -> str:
        restarts = await self._memory.recent_restarts(minutes=minutes)
        if not restarts:
            return "No auto-restarts in this time window."
        lines = [f"Auto-restarts ({len(restarts)}) in last {minutes} min:"]
        for r in restarts[:15]:
            ts = r.get("created_at", "?")
            if isinstance(ts, str) and len(ts) > 16:
                ts = ts[:16]
            room = r.get("project", "?")
            lines.append(f"  [{ts}] {room}")
        return "\n".join(lines)

    # ── Agency tool handlers ──────────────────────────────────────

    async def _handle_agency_ask(self, args: dict[str, Any]) -> str:
        self._last_routing: dict[str, Any] = {}
        question = args.get("question", "")
        if not question:
            return "Error: question is required."

        if self._agency_router is not None:
            result = await self._agency_router.route_and_ask(question)
            if result.get("error"):
                return result["error"]
            # Capture routing metadata for the concierge logger.
            self._last_routing = {
                "department": result.get("department"),
                "agent_name": result.get("agent_name"),
                "confidence": result.get("confidence"),
                "routing_method": result.get("routing_method"),
                "also_relevant": [
                    r["department"] for r in result.get("also_relevant", [])[:3]
                ],
            }
            lines = [f"Department: {result['department']} ({result['agent_name']})"]
            also = [r["department"] for r in result.get("also_relevant", [])[:2]]
            if also:
                lines.append(f"Also relevant: {', '.join(also)}")
            lines.append("")
            lines.append(result["answer"])
            return "\n".join(lines)

        return "Agency routing unavailable."

    def _handle_who_handles(self, args: dict[str, Any]) -> str:
        topic = args.get("topic", "")
        if not topic:
            return "Error: topic is required."

        if self._agency_router is None:
            return "Agency routing unavailable."

        results = self._agency_router.keyword_search(topic)
        if not results:
            return f"No departments found for topic: {topic}"
        lines = [f"Departments handling '{topic}':"]
        for r in results[:5]:
            lines.append(
                f"  {r['department']} ({r['agent_name']})"
                f" — score {r['score']}, matches: {', '.join(r['matches'])}"
            )
        return "\n".join(lines)

    def _handle_agency_list(self) -> str:
        if self._agency_router is None:
            return "Agency routing unavailable."
        agents_data = self._agency_router.agents
        lines = [f"Maude Agency — {len(agents_data)} departments:"]
        for dept in sorted(agents_data):
            info = agents_data[dept]
            lines.append(f"  {dept}: {info['agent_name']} — {info['role']}")
        return "\n".join(lines)

    async def _handle_search_agents(self, args: dict[str, Any]) -> str:
        query = args.get("query", "")
        if not query:
            return "Error: query is required."
        top_k = args.get("top_k", 5)

        from maude.coordination.search import AGENTS_COLLECTION, _embed, _qdrant_search

        try:
            embedding = await _embed(query)
        except Exception as e:
            return f"Embedding failed: {e}"

        hits = await _qdrant_search(AGENTS_COLLECTION, embedding, top_k)
        if not hits:
            return "No results found."
        lines = [f"Search results for '{query}':"]
        for hit in hits:
            payload = hit.get("payload", {})
            dept = payload.get("department", "?")
            section = payload.get("section", "?")
            score = round(hit.get("score", 0.0), 4)
            preview = payload.get("content", "")[:200]
            lines.append(f"  [{score}] {dept} / {section}: {preview}")
        return "\n".join(lines)
