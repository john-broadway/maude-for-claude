# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.llm.guardrails — NeMo Guardrails backend wrapper.

         Claude (Anthropic) <noreply@anthropic.com>
"""

from typing import Any
from unittest.mock import patch

import pytest

from maude.llm.guardrails import GuardrailsBackend, _is_blocked, wrap_if_enabled
from maude.llm.types import LLMResponse, ToolCall

# ── Fake backend ────────────────────────────────────────────────────


class FakeLLMBackend:
    """Minimal LLMBackend fake for testing guardrails wrapper."""

    def __init__(self, response: LLMResponse | None = None) -> None:
        self._response = response or LLMResponse(
            content="Here is the answer.",
            model="test-model",
            tokens_used=42,
            stop_reason="end_turn",
        )
        self.send_count = 0
        self.closed = False

    async def send(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
        tool_choice: str | None = None,
    ) -> LLMResponse:
        self.send_count += 1
        return self._response

    async def close(self) -> None:
        self.closed = True


# ── _is_blocked ─────────────────────────────────────────────────────


def test_is_blocked_detects_refusal():
    assert _is_blocked("I'm not able to help with that.") is True
    assert _is_blocked("I cannot provide that information.") is True
    assert _is_blocked("Sorry, I can't do that.") is True


def test_is_blocked_passes_normal():
    assert _is_blocked("Here is the server status.") is False
    assert _is_blocked("The service is running on port 8000.") is False


def test_is_blocked_empty():
    assert _is_blocked("") is False


# ── GuardrailsBackend without nemo ──────────────────────────────────


@pytest.mark.asyncio
async def test_passthrough_when_nemo_not_available():
    """When nemoguardrails isn't installed, wrapper passes through."""
    backend = FakeLLMBackend()

    with patch("maude.llm.guardrails._HAS_NEMO", False):
        wrapper = GuardrailsBackend(backend)

    assert not wrapper.available

    messages = [{"role": "user", "content": "What is the service status?"}]
    result = await wrapper.send(messages)

    assert result.content == "Here is the answer."
    assert backend.send_count == 1


@pytest.mark.asyncio
async def test_passthrough_when_config_dir_missing():
    """When config dir doesn't exist, wrapper passes through."""
    backend = FakeLLMBackend()

    with patch("maude.llm.guardrails._HAS_NEMO", True):
        wrapper = GuardrailsBackend(backend, config_dir="/nonexistent/path/that/doesnt/exist")

    assert not wrapper.available

    messages = [{"role": "user", "content": "test"}]
    result = await wrapper.send(messages)
    assert result.content == "Here is the answer."
    assert backend.send_count == 1


@pytest.mark.asyncio
async def test_close_delegates():
    """close() delegates to underlying backend."""
    backend = FakeLLMBackend()

    with patch("maude.llm.guardrails._HAS_NEMO", False):
        wrapper = GuardrailsBackend(backend)

    await wrapper.close()
    assert backend.closed is True


# ── wrap_if_enabled ─────────────────────────────────────────────────


def test_wrap_if_enabled_returns_original_when_disabled():
    """When guardrails.enabled is false, returns original backend."""
    backend = FakeLLMBackend()
    config = {"vllm": {"model": "test"}, "guardrails": {"enabled": False}}

    result = wrap_if_enabled(backend, config)
    assert result is backend


def test_wrap_if_enabled_returns_original_when_missing():
    """When guardrails section is absent, returns original backend."""
    backend = FakeLLMBackend()
    config = {"vllm": {"model": "test"}}

    result = wrap_if_enabled(backend, config)
    assert result is backend


def test_wrap_if_enabled_wraps_when_enabled():
    """When guardrails.enabled is true, returns GuardrailsBackend."""
    backend = FakeLLMBackend()
    config = {"vllm": {"model": "test"}, "guardrails": {"enabled": True}}

    with patch("maude.llm.guardrails._HAS_NEMO", False):
        result = wrap_if_enabled(backend, config)

    assert isinstance(result, GuardrailsBackend)


# ── Tool call passthrough ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_tool_calls_pass_through():
    """Responses with tool calls skip output rail check."""
    response = LLMResponse(
        content="",
        tool_calls=[ToolCall(id="1", name="service_health", arguments={})],
        model="test",
        stop_reason="tool_use",
    )
    backend = FakeLLMBackend(response=response)

    with patch("maude.llm.guardrails._HAS_NEMO", False):
        wrapper = GuardrailsBackend(backend)

    messages = [{"role": "user", "content": "check health"}]
    result = await wrapper.send(messages)

    assert len(result.tool_calls) == 1
    assert result.tool_calls[0].name == "service_health"


# ── LLMRouter integration ──────────────────────────────────────────


def test_router_from_config_wraps_primary():
    """LLMRouter.from_config wraps primary with guardrails when enabled."""
    from maude.llm.router import LLMRouter

    config = {
        "vllm": {"model": "test-model", "temperature": 0.2},
        "guardrails": {"enabled": True},
    }

    with patch("maude.llm.guardrails._HAS_NEMO", False):
        router = LLMRouter.from_config(config)

    # Primary should be wrapped (GuardrailsBackend wrapping VLLMBackend)
    assert isinstance(router.primary, GuardrailsBackend)


def test_router_from_config_no_wrap_when_disabled():
    """LLMRouter.from_config does NOT wrap when guardrails disabled."""
    from maude.llm.router import LLMRouter

    config = {
        "vllm": {"model": "test-model", "temperature": 0.2},
        "guardrails": {"enabled": False},
    }

    router = LLMRouter.from_config(config)

    # Primary should be raw VLLMBackend, not wrapped
    assert not isinstance(router.primary, GuardrailsBackend)
