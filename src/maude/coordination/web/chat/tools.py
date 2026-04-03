# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Chat tool schemas and system prompt."""

from typing import Any

CHAT_TOOLS: list[dict[str, Any]] = [
    {
        "name": "room_status",
        "description": (
            "Get a summary of all room status across the hotel (run counts, outcomes, health)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "minutes": {
                    "type": "integer",
                    "description": "Lookback window in minutes (default 60).",
                },
            },
        },
    },
    {
        "name": "hotel_briefing",
        "description": (
            "Generate a full hotel briefing covering room health,"
            " incidents, escalations, and dependency risks."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {
                    "type": "string",
                    "description": (
                        "Scope: 'all' for full hotel, or 'room:<name>' for a single room."
                    ),
                },
                "minutes": {
                    "type": "integer",
                    "description": "Lookback window in minutes (default 60).",
                },
            },
        },
    },
    {
        "name": "room_dependencies",
        "description": (
            "Show what a room depends on, what depends on it,"
            " and transitive impact if it goes down."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "room": {
                    "type": "string",
                    "description": "Room name (e.g. 'postgresql', 'my-service').",
                },
            },
            "required": ["room"],
        },
    },
    {
        "name": "recent_incidents",
        "description": "List recent incidents (resolved, failed, escalated) across all rooms.",
        "parameters": {
            "type": "object",
            "properties": {
                "minutes": {
                    "type": "integer",
                    "description": "Lookback window in minutes (default 60).",
                },
            },
        },
    },
    {
        "name": "recent_escalations",
        "description": "List recent escalations across all rooms.",
        "parameters": {
            "type": "object",
            "properties": {
                "minutes": {
                    "type": "integer",
                    "description": "Lookback window in minutes (default 60).",
                },
            },
        },
    },
    {
        "name": "recent_restarts",
        "description": (
            "List recent auto-restart events triggered by health loops across all rooms."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "minutes": {
                    "type": "integer",
                    "description": "Lookback window in minutes (default 60).",
                },
            },
        },
    },
    {
        "name": "agency_ask",
        "description": (
            "Ask the Maude agency a question — auto-routes to the best department"
            " agent and returns an expert answer. Use this for any question"
            " about Maude operations, processes, standards, or departments."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "Natural language question about Maude operations.",
                },
            },
            "required": ["question"],
        },
    },
    {
        "name": "agency_who_handles",
        "description": (
            "Find which Maude departments handle a topic or responsibility"
            " (e.g., 'compliance qualification', 'ITAR compliance')."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "topic": {
                    "type": "string",
                    "description": "The topic to search for.",
                },
            },
            "required": ["topic"],
        },
    },
    {
        "name": "agency_list",
        "description": "List all department agents with their names and roles.",
        "parameters": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "search_agents",
        "description": (
            "Semantic search over department agent knowledge"
            " (vector search across all agent.md files)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Natural language search query.",
                },
                "top_k": {
                    "type": "integer",
                    "description": "Max results to return (default 5).",
                },
            },
            "required": ["query"],
        },
    },
]

SYSTEM_PROMPT = """You are Maude, an AI assistant that manages \
autonomous infrastructure rooms for your organization.

Your demeanor is formal, polished, and professional — like a luxury hotel concierge. \
You address guests with respect and use hotel terminology: "Rooms" (not services), \
"Maude" (not the cluster), "guests" (not users).

You have access to two sets of tools:

1. **Hotel tools** — room status, incidents, dependencies, briefings. Use these \
for questions about infrastructure health and operational state.

2. **Agency tools** — department agents covering all Maude operations \
(engineering, quality, sales, production, etc.). Use `agency_ask` when guests \
ask about Maude processes, standards, regulations, or departmental responsibilities. \
Use `agency_who_handles` to find which department owns a topic. Use `search_agents` \
for semantic search across department knowledge.

When a guest asks about Maude operations, processes, standards (AS9100, NADCAP, ITAR, etc.), \
or departmental questions, use the agency tools. For infrastructure/room questions, \
use the hotel tools.

Keep responses brief — 2-4 sentences for simple queries, more for briefings. \
Never fabricate data. If you don't know, say so."""
