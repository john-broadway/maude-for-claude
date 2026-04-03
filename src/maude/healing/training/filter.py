# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Training data filters — ITAR, PII, quality, and language enforcement.

Applied before exporting concierge conversations to training JSONL.
Each filter returns the cleaned conversation or None to skip it entirely.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from maude.healing.training.export import check_conversation_english

# ── PII patterns ──────────────────────────────────────────────────

_EMAIL_RE = re.compile(r"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+")
_PHONE_RE = re.compile(r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b")
_SSN_RE = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")

REDACTED = "[REDACTED]"


@dataclass
class TrainingFilterConfig:
    """Configuration for training data filters."""

    itar_patterns: list[str] = field(default_factory=lambda: [
        "USML", "ITAR", "EAR99", "export controlled",
        "defense article", "technical data",
    ])
    min_messages: int = 2
    error_phrases: list[str] = field(default_factory=lambda: [
        "All LLM backends unavailable",
        "I apologize — I was unable to complete",
    ])

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> TrainingFilterConfig:
        if not data:
            return cls()
        defaults = cls()
        return cls(
            itar_patterns=data.get("itar_patterns", defaults.itar_patterns),
            min_messages=data.get("min_messages", defaults.min_messages),
            error_phrases=data.get("error_phrases", defaults.error_phrases),
        )


def _conversation_text(messages: list[dict[str, Any]]) -> str:
    """Concatenate all text content from a message list."""
    parts: list[str] = []
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, str):
            parts.append(content)
    return " ".join(parts)


def check_itar(messages: list[dict[str, Any]], patterns: list[str]) -> bool:
    """Return True if conversation contains ITAR markers.

    Scans all message content (case-insensitive) for any pattern.
    """
    text = _conversation_text(messages).lower()
    return any(p.lower() in text for p in patterns)


def scrub_pii(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Replace PII (emails, phones, SSNs) with [REDACTED]."""
    cleaned: list[dict[str, Any]] = []
    for msg in messages:
        out = dict(msg)
        content = out.get("content", "")
        if isinstance(content, str):
            content = _EMAIL_RE.sub(REDACTED, content)
            content = _PHONE_RE.sub(REDACTED, content)
            content = _SSN_RE.sub(REDACTED, content)
            out["content"] = content
        cleaned.append(out)
    return cleaned


def check_quality(
    messages: list[dict[str, Any]],
    min_messages: int,
    error_phrases: list[str],
) -> bool:
    """Return True if conversation passes quality gate.

    Fails if:
    - Fewer than ``min_messages`` messages
    - Last assistant message is an error phrase
    """
    if len(messages) < min_messages:
        return False

    # Check last assistant message for error content.
    for msg in reversed(messages):
        if msg.get("role") == "assistant":
            content = msg.get("content", "")
            if isinstance(content, str):
                for phrase in error_phrases:
                    if phrase in content:
                        return False
            break

    return True


def filter_conversation(
    messages: list[dict[str, Any]],
    config: TrainingFilterConfig | None = None,
) -> list[dict[str, Any]] | None:
    """Apply all filters to a conversation.

    Returns:
        Cleaned messages ready for training export, or None to skip.
    """
    if config is None:
        config = TrainingFilterConfig()

    # ITAR — entire conversation excluded.
    if check_itar(messages, config.itar_patterns):
        return None

    # Quality gate.
    if not check_quality(messages, config.min_messages, config.error_phrases):
        return None

    # Language filter.
    if not check_conversation_english(messages):
        return None

    # PII scrub (applied to passing conversations).
    return scrub_pii(messages)
