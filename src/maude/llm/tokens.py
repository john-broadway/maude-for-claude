# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Maude LLM Token Estimation — context budget planning
#          Claude (Anthropic) <noreply@anthropic.com>
"""Lightweight token estimation for context budget planning.

Uses a 4-chars-per-token heuristic — accurate enough for budget
planning without requiring a tokenizer dependency.
"""

from __future__ import annotations

import json
from typing import Any

# Average chars per token for English text (conservative estimate)
_CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
    """Estimate token count from text length.

    Uses 4-chars-per-token heuristic — within ~10% of actual for
    English text. Underestimates for CJK, overestimates for code.
    """
    return max(1, len(text) // _CHARS_PER_TOKEN) if text else 0


def context_budget(
    system_prompt: str,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]] | None = None,
    max_context: int = 131072,
) -> dict[str, Any]:
    """Estimate context window utilization.

    Returns:
        dict with 'used', 'available', 'utilization' (0.0-1.0),
        and per-component breakdown.
    """
    system_tokens = estimate_tokens(system_prompt)

    message_tokens = 0
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, str):
            message_tokens += estimate_tokens(content)
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict):
                    message_tokens += estimate_tokens(str(part.get("text", "")))
        # Per-message overhead (role, formatting)
        message_tokens += 4

    tool_tokens = 0
    if tools:
        tool_tokens = estimate_tokens(json.dumps(tools))

    used = system_tokens + message_tokens + tool_tokens
    available = max(0, max_context - used)
    utilization = used / max_context if max_context > 0 else 1.0

    return {
        "used": used,
        "available": available,
        "utilization": round(utilization, 4),
        "max_context": max_context,
        "breakdown": {
            "system": system_tokens,
            "messages": message_tokens,
            "tools": tool_tokens,
        },
    }
