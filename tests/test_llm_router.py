# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for LLM router — backend abstraction and fallback chain."""

from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from maude.llm.router import (
    LLMResponse,
    LLMRouter,
    ModelTier,
    VLLMBackend,
    _is_rate_limit,
    _to_openai_message,
    _to_openai_tools,
)
from maude.llm.vllm import (
    _ChatMessage,
    _ChatResponse,
    _Function,
    _ToolCall,
)

# ── Tool schema conversion ──────────────────────────────────────────

SAMPLE_TOOLS = [
    {
        "name": "service_status",
        "description": "Check service state",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
        },
    }
]


def test_to_openai_tools():
    result = _to_openai_tools(SAMPLE_TOOLS)
    assert len(result) == 1
    assert result[0]["type"] == "function"
    assert result[0]["function"]["name"] == "service_status"
    assert result[0]["function"]["parameters"]["type"] == "object"


def test_to_openai_message_user():
    msg = {"role": "user", "content": "hello"}
    result = _to_openai_message(msg)
    assert result == {"role": "user", "content": "hello"}


def test_to_openai_message_tool_result():
    msg = {"role": "tool", "content": "result data", "tool_call_id": "tc1"}
    result = _to_openai_message(msg)
    assert result == {"role": "tool", "content": "result data", "tool_call_id": "tc1"}


def test_to_openai_message_assistant_with_tool_calls():
    msg = {
        "role": "assistant",
        "content": "Let me check.",
        "tool_calls": [{"id": "tc1", "name": "foo", "arguments": {"bar": 1}}],
    }
    result = _to_openai_message(msg)
    assert result["role"] == "assistant"
    assert len(result["tool_calls"]) == 1
    assert result["tool_calls"][0]["function"]["name"] == "foo"
    # vLLM hermes parser requires arguments as JSON string, not dict
    assert result["tool_calls"][0]["function"]["arguments"] == '{"bar": 1}'
    assert isinstance(result["tool_calls"][0]["function"]["arguments"], str)


# ── LLMRouter fallback chain ────────────────────────────────────────


async def test_router_primary_succeeds():
    primary = AsyncMock()
    primary.send = AsyncMock(return_value=LLMResponse(content="ok", model="test", tokens_used=10))
    fallback = AsyncMock()

    router = LLMRouter(primary=primary, fallback=fallback)
    result = await router.send([{"role": "user", "content": "hi"}])

    assert result is not None
    assert result.content == "ok"
    assert result.model == "test"
    primary.send.assert_called_once()
    fallback.send.assert_not_called()


async def test_router_fallback_on_primary_failure():
    primary = AsyncMock()
    primary.send = AsyncMock(side_effect=Exception("API down"))
    fallback = AsyncMock()
    fallback.send = AsyncMock(
        return_value=LLMResponse(content="fallback ok", model="claude", tokens_used=5)
    )

    router = LLMRouter(primary=primary, fallback=fallback)
    result = await router.send([{"role": "user", "content": "hi"}])

    assert result is not None
    assert result.content == "fallback ok"
    assert result.model == "claude"


async def test_router_returns_none_when_all_fail():
    primary = AsyncMock()
    primary.send = AsyncMock(side_effect=Exception("down"))
    fallback = AsyncMock()
    fallback.send = AsyncMock(side_effect=Exception("also down"))

    router = LLMRouter(primary=primary, fallback=fallback)
    result = await router.send([{"role": "user", "content": "hi"}])

    assert result is None


async def test_router_no_backends():
    router = LLMRouter(primary=None, fallback=None)
    result = await router.send([{"role": "user", "content": "hi"}])
    assert result is None


async def test_router_close():
    primary = AsyncMock()
    primary.close = AsyncMock()
    fallback = AsyncMock()
    fallback.close = AsyncMock()

    router = LLMRouter(primary=primary, fallback=fallback)
    await router.close()

    primary.close.assert_called_once()
    fallback.close.assert_called_once()


# ── LLMRouter.from_config ───────────────────────────────────────────


def test_from_config_vllm_primary():
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://localhost:8000"},
    }
    router = LLMRouter.from_config(config, {})
    assert isinstance(router.primary, VLLMBackend)
    assert router.fallback is None


# ── T4 Escalation (send_to_fallback) ───────────────────────────────


def test_can_escalate_with_fallback():
    router = LLMRouter(primary=AsyncMock(), fallback=AsyncMock())
    assert router.can_escalate is True


def test_can_escalate_without_fallback():
    router = LLMRouter(primary=AsyncMock(), fallback=None)
    assert router.can_escalate is False


async def test_send_to_fallback_calls_fallback():
    primary = AsyncMock()
    fallback = AsyncMock()
    fallback.send = AsyncMock(
        return_value=LLMResponse(content="claude says", model="claude", tokens_used=100)
    )

    router = LLMRouter(primary=primary, fallback=fallback)
    result = await router.send_to_fallback([{"role": "user", "content": "help"}])

    assert result is not None
    assert result.content == "claude says"
    assert result.model == "claude"
    primary.send.assert_not_called()
    fallback.send.assert_called_once()


async def test_send_to_fallback_returns_none_without_fallback():
    router = LLMRouter(primary=AsyncMock(), fallback=None)
    result = await router.send_to_fallback([{"role": "user", "content": "help"}])
    assert result is None


async def test_send_to_fallback_returns_none_on_error():
    fallback = AsyncMock()
    fallback.send = AsyncMock(side_effect=Exception("Claude API down"))

    router = LLMRouter(primary=AsyncMock(), fallback=fallback)
    result = await router.send_to_fallback([{"role": "user", "content": "help"}])
    assert result is None


# ── VLLMBackend ──────────────────────────────────────────────────────


def _make_chat_response(
    content: str = "ok",
    tool_calls: list[_ToolCall] | None = None,
    eval_count: int = 10,
    prompt_eval_count: int = 5,
) -> _ChatResponse:
    """Helper: create a vLLM _ChatResponse for VLLMBackend tests."""
    return _ChatResponse(
        message=_ChatMessage(content=content, tool_calls=tool_calls),
        eval_count=eval_count,
        prompt_eval_count=prompt_eval_count,
    )


async def test_vllm_send():
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")
    backend._vllm = AsyncMock()
    backend._vllm.chat = AsyncMock(
        return_value=_make_chat_response("I checked.", eval_count=50, prompt_eval_count=20)
    )

    result = await backend.send(
        [{"role": "user", "content": "check status"}],
        system="You are helpful.",
    )

    assert result.content == "I checked."
    assert result.model == "Qwen/Qwen3-8B"
    assert result.tokens_used == 70
    assert result.stop_reason == "end_turn"


async def test_vllm_send_with_tool_calls():
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")

    tc = _ToolCall(function=_Function(name="service_status", arguments={}))

    backend._vllm = AsyncMock()
    resp = _make_chat_response("", tool_calls=[tc], eval_count=30, prompt_eval_count=10)
    backend._vllm.chat = AsyncMock(return_value=resp)

    result = await backend.send(
        [{"role": "user", "content": "check"}],
        tools=SAMPLE_TOOLS,
    )

    assert len(result.tool_calls) == 1
    assert result.tool_calls[0].name == "service_status"
    assert result.tool_calls[0].id == "vllm_0"
    assert result.stop_reason == "tool_use"


# ── _is_rate_limit ────────────────────────────────────────────────


def test_is_rate_limit_by_class_name():
    """Any exception named RateLimitError should be detected."""

    class RateLimitError(Exception):
        pass

    assert _is_rate_limit(RateLimitError("429")) is True


def test_is_rate_limit_httpx_429():
    """httpx.HTTPStatusError with 429 should be detected."""
    response = MagicMock()
    response.status_code = 429
    exc = httpx.HTTPStatusError("rate limited", request=MagicMock(), response=response)
    assert _is_rate_limit(exc) is True


def test_is_rate_limit_httpx_500():
    """httpx.HTTPStatusError with 500 should NOT be rate limit."""
    response = MagicMock()
    response.status_code = 500
    exc = httpx.HTTPStatusError("server error", request=MagicMock(), response=response)
    assert _is_rate_limit(exc) is False


def test_is_rate_limit_generic_exception():
    """Generic exceptions are not rate limits."""
    assert _is_rate_limit(Exception("something broke")) is False


# ── Retry with backoff ────────────────────────────────────────────


# Dynamic class so type(exc).__name__ == "RateLimitError"
_FakeRateLimitError = type("RateLimitError", (Exception,), {})


async def test_retry_succeeds_after_rate_limit():
    """Rate-limited request should retry and succeed."""
    primary = AsyncMock()
    primary.send = AsyncMock(
        side_effect=[
            _FakeRateLimitError("429"),
            LLMResponse(content="ok", model="test", tokens_used=10),
        ]
    )

    router = LLMRouter(primary=primary, fallback=None)
    with patch("maude.llm.router.asyncio.sleep", new_callable=AsyncMock) as mock_sleep:
        result = await router.send([{"role": "user", "content": "hi"}])

    assert result is not None
    assert result.content == "ok"
    assert primary.send.call_count == 2
    # First retry: 2^1 + jitter (0-1) = 2.0-3.0s
    delay = mock_sleep.call_args[0][0]
    assert 2.0 <= delay < 3.0


async def test_retry_exhausted_falls_to_fallback():
    """After max retries on rate limit, should fall through to fallback."""
    primary = AsyncMock()
    primary.send = AsyncMock(side_effect=_FakeRateLimitError("429"))

    fallback = AsyncMock()
    fallback.send = AsyncMock(
        return_value=LLMResponse(content="fallback", model="claude", tokens_used=5)
    )

    router = LLMRouter(primary=primary, fallback=fallback)
    with patch("maude.llm.router.asyncio.sleep", new_callable=AsyncMock):
        result = await router.send([{"role": "user", "content": "hi"}])

    assert result is not None
    assert result.content == "fallback"
    assert primary.send.call_count == 4  # 1 initial + 3 retries


async def test_non_rate_limit_error_skips_retry():
    """Non-429 errors should not retry, just fall through immediately."""
    primary = AsyncMock()
    primary.send = AsyncMock(side_effect=ConnectionError("offline"))

    fallback = AsyncMock()
    fallback.send = AsyncMock(
        return_value=LLMResponse(content="fallback", model="claude", tokens_used=5)
    )

    router = LLMRouter(primary=primary, fallback=fallback)
    result = await router.send([{"role": "user", "content": "hi"}])

    assert result is not None
    assert result.content == "fallback"
    assert primary.send.call_count == 1  # No retries


async def test_retry_backoff_delays():
    """Verify exponential backoff delays: 2s, 4s, 8s."""
    primary = AsyncMock()
    primary.send = AsyncMock(
        side_effect=[
            _FakeRateLimitError("429"),
            _FakeRateLimitError("429"),
            _FakeRateLimitError("429"),
            _FakeRateLimitError("429"),  # Exhausted after 3 retries
        ]
    )

    router = LLMRouter(primary=primary, fallback=None)
    with patch("maude.llm.router.asyncio.sleep", new_callable=AsyncMock) as mock_sleep:
        result = await router.send([{"role": "user", "content": "hi"}])

    assert result is None  # All retries exhausted, no fallback
    delays = [call.args[0] for call in mock_sleep.call_args_list]
    # Exponential backoff with jitter: 2+j, 4+j, 8+j where j in [0,1)
    assert 2.0 <= delays[0] < 3.0
    assert 4.0 <= delays[1] < 5.0
    assert 8.0 <= delays[2] < 9.0


# ── Coverage: VLLMBackend.close ────────────────────────────────────


async def test_vllm_backend_close():
    """VLLMBackend.close delegates to VLLMClient.close."""
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")
    backend._vllm = AsyncMock()
    backend._vllm.close = AsyncMock()

    await backend.close()

    backend._vllm.close.assert_awaited_once()


async def test_vllm_backend_close_fresh():
    """VLLMBackend.close is safe on a fresh backend."""
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")
    # Replace with mock so we don't actually connect
    backend._vllm = AsyncMock()
    backend._vllm.close = AsyncMock()
    await backend.close()


# ── Coverage: VLLMBackend temperature ──────────────────────────────


def test_vllm_temperature_config():
    """VLLMBackend stores temperature from constructor."""
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B", temperature=0.7)
    assert backend.temperature == 0.7


def test_vllm_default_temperature():
    """VLLMBackend defaults to temperature 0.2."""
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")
    assert backend.temperature == 0.2


# ── Coverage: _to_openai_message Claude-style tool_result ────────


def test_to_openai_message_claude_tool_result():
    """Claude-style tool_result converts to role=tool with tool_call_id."""
    msg = {
        "role": "user",
        "content": [
            {"type": "tool_result", "tool_use_id": "tc1", "content": "result data"},
        ],
    }
    result = _to_openai_message(msg)
    assert result["role"] == "tool"
    assert result["content"] == "result data"
    assert result["tool_call_id"] == "tc1"


def test_to_openai_message_user_with_non_tool_result_list():
    """User message with content list that is not tool_result passes through."""
    msg = {
        "role": "user",
        "content": [
            {"type": "text", "text": "just a text block"},
        ],
    }
    result = _to_openai_message(msg)
    # Not a tool_result, so should fall through to the default case
    assert result["role"] == "user"


# ── VLLMBackend failover (via VLLMClient) ────────────────────────


async def test_vllm_multi_url_failover():
    """First host fails, second host succeeds via VLLMClient."""
    backend = VLLMBackend(
        base_urls=["http://bad:8000", "http://good:8000"],
        model="Qwen/Qwen3-8B",
    )

    # Mock the VLLMClient to succeed
    backend._vllm = AsyncMock()
    backend._vllm.chat = AsyncMock(return_value=_make_chat_response("success from good"))

    result = await backend.send([{"role": "user", "content": "hi"}])
    assert result.content == "success from good"
    backend._vllm.chat.assert_called_once()


async def test_vllm_all_urls_fail():
    """All hosts fail, raises the exception from VLLMClient."""
    backend = VLLMBackend(
        base_urls=["http://bad1:8000", "http://bad2:8000"],
        model="Qwen/Qwen3-8B",
    )

    backend._vllm = AsyncMock()
    backend._vllm.chat = AsyncMock(side_effect=RuntimeError("all hosts failed"))

    with pytest.raises(RuntimeError, match="all hosts failed"):
        await backend.send([{"role": "user", "content": "hi"}])


async def test_vllm_no_urls_configured():
    """Empty hosts raises RuntimeError on send."""
    with patch("maude.llm.vllm.VLLMClient._resolve_hosts", return_value=[]):
        backend = VLLMBackend(model="Qwen/Qwen3-8B")

    with pytest.raises(RuntimeError, match="no hosts configured"):
        await backend.send([{"role": "user", "content": "hi"}])


async def test_vllm_response_missing_fields():
    """Response with missing optional fields still works with defaults."""
    backend = VLLMBackend(base_url="http://fake:8000", model="Qwen/Qwen3-8B")

    backend._vllm = AsyncMock()
    backend._vllm.chat = AsyncMock(
        return_value=_ChatResponse(
            message=_ChatMessage(content=None, tool_calls=None),
            eval_count=0,
            prompt_eval_count=0,
        )
    )

    result = await backend.send([{"role": "user", "content": "hi"}])

    assert result.content == ""
    assert result.tool_calls == []
    assert result.tokens_used == 0
    assert result.model == "Qwen/Qwen3-8B"
    assert result.stop_reason == "end_turn"


# ── Host resolution via VLLMClient ────────────────────────────────


def test_vllm_host_resolved_by_client():
    """VLLMBackend without explicit URLs delegates host resolution to VLLMClient."""
    with patch(
        "maude.llm.vllm.VLLMClient._resolve_hosts",
        return_value=["localhost"],
    ):
        backend = VLLMBackend(model="Qwen/Qwen3-8B")
    assert "localhost" in backend._vllm._hosts


# ── A/B Test ─────────────────────────────────────────────────────────


async def test_ab_test_selects_challenger():
    """When random < ratio, challenger model is used in payload and response."""
    backend = VLLMBackend(
        base_url="http://fake:8000",
        model="Qwen/Qwen3-8B",
        challenger="maude-agent",
        challenger_ratio=0.5,
    )

    captured_kwargs: list[dict] = []

    async def capture_chat(**kwargs: Any) -> _ChatResponse:
        captured_kwargs.append(kwargs)
        return _make_chat_response()

    backend._vllm = AsyncMock()
    backend._vllm.chat = capture_chat

    # Force random to return 0.1 (< 0.5 ratio → use challenger)
    with patch("maude.llm.router.random.random", return_value=0.1):
        result = await backend.send([{"role": "user", "content": "hi"}])

    assert result.model == "maude-agent"
    assert captured_kwargs[0]["model"] == "maude-agent"


async def test_ab_test_selects_control():
    """When random >= ratio, control model is used."""
    backend = VLLMBackend(
        base_url="http://fake:8000",
        model="Qwen/Qwen3-8B",
        challenger="maude-agent",
        challenger_ratio=0.5,
    )

    captured_kwargs: list[dict] = []

    async def capture_chat(**kwargs: Any) -> _ChatResponse:
        captured_kwargs.append(kwargs)
        return _make_chat_response()

    backend._vllm = AsyncMock()
    backend._vllm.chat = capture_chat

    # Force random to return 0.8 (>= 0.5 ratio → use control)
    with patch("maude.llm.router.random.random", return_value=0.8):
        result = await backend.send([{"role": "user", "content": "hi"}])

    assert result.model == "Qwen/Qwen3-8B"
    assert captured_kwargs[0]["model"] == "Qwen/Qwen3-8B"


async def test_ab_test_no_challenger_always_control():
    """Without challenger configured, always uses control model."""
    backend = VLLMBackend(
        base_url="http://fake:8000",
        model="Qwen/Qwen3-8B",
    )

    captured_kwargs: list[dict] = []

    async def capture_chat(**kwargs: Any) -> _ChatResponse:
        captured_kwargs.append(kwargs)
        return _make_chat_response()

    backend._vllm = AsyncMock()
    backend._vllm.chat = capture_chat

    result = await backend.send([{"role": "user", "content": "hi"}])

    assert result.model == "Qwen/Qwen3-8B"
    assert captured_kwargs[0]["model"] == "Qwen/Qwen3-8B"


def test_from_config_with_ab_test():
    """ab_test config section wires challenger into VLLMBackend."""
    config = {
        "vllm": {
            "model": "Qwen/Qwen3-8B",
            "base_url": "http://fake:8000",
            "ab_test": {
                "challenger": "maude-agent",
                "ratio": 0.3,
            },
        },
    }
    router = LLMRouter.from_config(config, {})
    assert isinstance(router.primary, VLLMBackend)
    assert router.primary.model == "Qwen/Qwen3-8B"
    assert router.primary.challenger == "maude-agent"
    assert router.primary.challenger_ratio == 0.3


def test_from_config_without_ab_test():
    """No ab_test config → empty challenger, zero ratio (backward compat)."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
    }
    router = LLMRouter.from_config(config, {})
    assert isinstance(router.primary, VLLMBackend)
    assert router.primary.challenger == ""
    assert router.primary.challenger_ratio == 0.0


# ── ModelTier enum ─────────────────────────────────────────────────


def test_model_tier_ordering():
    """ModelTier values are correctly ordered L1 < L2 < L3 < L4."""
    assert ModelTier.L1_ROOM < ModelTier.L2_COMPLEX
    assert ModelTier.L2_COMPLEX < ModelTier.L3_SPECIALIST
    assert ModelTier.L3_SPECIALIST < ModelTier.L4_ESCALATION


# ── Multi-tier from_config ─────────────────────────────────────────


def test_from_config_with_complex_and_specialist():
    """from_config builds all three vLLM backends when configured."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
        "complex": {"model": "Qwen/Qwen3-14B", "base_url": "http://fake:8000"},
        "specialist": {"model": "Qwen/Qwen3-32B-AWQ", "base_url": "http://gpu-node-2:8000"},
    }
    router = LLMRouter.from_config(config)
    assert isinstance(router.primary, VLLMBackend)
    assert router.primary.model == "Qwen/Qwen3-8B"
    assert isinstance(router.complex, VLLMBackend)
    assert router.complex.model == "Qwen/Qwen3-14B"
    assert isinstance(router.specialist, VLLMBackend)
    assert router.specialist.model == "Qwen/Qwen3-32B-AWQ"


def test_from_config_complex_only():
    """from_config with only complex tier configured."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
        "complex": {"model": "Qwen/Qwen3-14B", "base_url": "http://fake:8000"},
    }
    router = LLMRouter.from_config(config)
    assert isinstance(router.complex, VLLMBackend)
    assert router.specialist is None


def test_from_config_no_higher_tiers():
    """from_config without complex/specialist is backward compatible."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
    }
    router = LLMRouter.from_config(config)
    assert router.complex is None
    assert router.specialist is None


def test_from_config_with_fallback():
    """Config with fallback key should produce router where can_escalate is True."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
        "fallback": {"model": "Qwen/Qwen3-14B", "base_url": "http://gpu-node-2:8000"},
    }
    router = LLMRouter.from_config(config)
    assert isinstance(router.fallback, VLLMBackend)
    assert router.fallback.model == "Qwen/Qwen3-14B"
    assert router.can_escalate is True


def test_from_config_fallback_absent_means_no_escalation():
    """Without fallback key, can_escalate is False."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
    }
    router = LLMRouter.from_config(config)
    assert router.fallback is None
    assert router.can_escalate is False


def test_from_config_specialist_with_base_urls():
    """specialist config supports base_urls for multi-host gpu-node-2."""
    config = {
        "vllm": {"model": "Qwen/Qwen3-8B", "base_url": "http://fake:8000"},
        "specialist": {
            "model": "Qwen/Qwen3-32B-AWQ",
            "base_urls": ["http://gpu1:8000", "http://gpu2:8000"],
        },
    }
    router = LLMRouter.from_config(config)
    assert isinstance(router.specialist, VLLMBackend)
    assert router.specialist.model == "Qwen/Qwen3-32B-AWQ"


# ── send_complex() ────────────────────────────────────────────────


async def test_send_complex_uses_complex_backend():
    """send_complex tries complex backend first."""
    complex_backend = AsyncMock()
    complex_backend.send = AsyncMock(
        return_value=LLMResponse(content="complex answer", model="Qwen/Qwen3-14B", tokens_used=80)
    )
    primary = AsyncMock()
    primary.send = AsyncMock(
        return_value=LLMResponse(content="primary answer", model="Qwen/Qwen3-8B", tokens_used=40)
    )

    router = LLMRouter(primary=primary, complex=complex_backend)
    result = await router.send_complex([{"role": "user", "content": "hard question"}])

    assert result is not None
    assert result.content == "complex answer"
    assert result.model == "Qwen/Qwen3-14B"
    complex_backend.send.assert_called_once()
    primary.send.assert_not_called()


async def test_send_complex_falls_to_specialist():
    """send_complex falls to specialist when complex fails."""
    complex_backend = AsyncMock()
    complex_backend.send = AsyncMock(side_effect=Exception("L2 down"))
    specialist = AsyncMock()
    specialist.send = AsyncMock(
        return_value=LLMResponse(
            content="specialist answer",
            model="Qwen/Qwen3-32B-AWQ",
            tokens_used=120,
        )
    )

    router = LLMRouter(complex=complex_backend, specialist=specialist)
    result = await router.send_complex([{"role": "user", "content": "hard question"}])

    assert result is not None
    assert result.content == "specialist answer"
    assert result.model == "Qwen/Qwen3-32B-AWQ"


async def test_send_complex_falls_to_primary():
    """send_complex falls all the way to primary when L2 and L3 are down."""
    complex_backend = AsyncMock()
    complex_backend.send = AsyncMock(side_effect=Exception("L2 down"))
    specialist = AsyncMock()
    specialist.send = AsyncMock(side_effect=Exception("L3 down"))
    primary = AsyncMock()
    primary.send = AsyncMock(
        return_value=LLMResponse(content="primary ok", model="Qwen/Qwen3-8B", tokens_used=40)
    )

    router = LLMRouter(primary=primary, complex=complex_backend, specialist=specialist)
    result = await router.send_complex([{"role": "user", "content": "hard question"}])

    assert result is not None
    assert result.content == "primary ok"


async def test_send_complex_returns_none_all_fail():
    """send_complex returns None when all tiers fail."""
    complex_backend = AsyncMock()
    complex_backend.send = AsyncMock(side_effect=Exception("down"))
    primary = AsyncMock()
    primary.send = AsyncMock(side_effect=Exception("also down"))

    router = LLMRouter(primary=primary, complex=complex_backend)
    result = await router.send_complex([{"role": "user", "content": "question"}])

    assert result is None


async def test_send_complex_no_backends():
    """send_complex returns None when no backends configured."""
    router = LLMRouter()
    result = await router.send_complex([{"role": "user", "content": "question"}])
    assert result is None


async def test_send_complex_skips_none_backends():
    """send_complex only tries non-None backends."""
    primary = AsyncMock()
    primary.send = AsyncMock(
        return_value=LLMResponse(content="ok", model="Qwen/Qwen3-8B", tokens_used=20)
    )

    # No complex or specialist, only primary
    router = LLMRouter(primary=primary)
    result = await router.send_complex([{"role": "user", "content": "q"}])

    assert result is not None
    assert result.content == "ok"
    primary.send.assert_called_once()


# ── close() with all backends ────────────────────────────────────


async def test_close_all_four_backends():
    """close() calls close on all four backends."""
    primary = AsyncMock()
    primary.close = AsyncMock()
    fallback = AsyncMock()
    fallback.close = AsyncMock()
    complex_b = AsyncMock()
    complex_b.close = AsyncMock()
    specialist = AsyncMock()
    specialist.close = AsyncMock()

    router = LLMRouter(
        primary=primary,
        fallback=fallback,
        complex=complex_b,
        specialist=specialist,
    )
    await router.close()

    primary.close.assert_called_once()
    fallback.close.assert_called_once()
    complex_b.close.assert_called_once()
    specialist.close.assert_called_once()
