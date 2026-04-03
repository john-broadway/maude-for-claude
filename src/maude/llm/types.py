# Maude LLM Types — shared across router, backends, and consumers
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Created: 2026-03-07 18:30 MST
"""LLM type definitions — shared across router, backends, and consumers."""

import enum
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


class ModelTier(enum.IntEnum):
    """Model capability tiers for multi-tier routing."""

    L1_ROOM = 1  # Per-room vLLM (Qwen3-8B) — routine checks
    L2_COMPLEX = 2  # Shared vLLM (Qwen3-14B) — complex reasoning
    L3_SPECIALIST = 3  # Heavyweight GPU vLLM (Qwen3-32B) — specialist
    L4_ESCALATION = 4  # T4 escalation (reserved)


@dataclass
class ToolCall:
    """A tool call requested by the LLM."""

    id: str
    name: str
    arguments: dict[str, Any]


@dataclass
class LLMResponse:
    """Unified response from any LLM backend."""

    content: str = ""
    tool_calls: list[ToolCall] = field(default_factory=list)
    model: str = ""
    tokens_used: int = 0  # Total tokens (prompt + completion)
    completion_tokens: int = 0  # Output tokens only — used for velocity tracking
    stop_reason: str = ""


@runtime_checkable
class LLMBackend(Protocol):
    """Protocol for LLM backends."""

    async def send(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
        tool_choice: str | None = None,
    ) -> LLMResponse: ...

    async def close(self) -> None: ...
