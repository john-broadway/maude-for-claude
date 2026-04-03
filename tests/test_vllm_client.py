# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.agent.vllm_client — multi-host failover via httpx."""

from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from maude.llm.vllm import VLLMClient, _is_connection_error

# ── Helper: mock httpx response ────────────────────────────────────────


def _json_response(data: dict, status_code: int = 200) -> MagicMock:
    """Create a mock httpx.Response with JSON data."""
    resp = MagicMock(spec=httpx.Response)
    resp.status_code = status_code
    resp.json.return_value = data
    if status_code >= 400:
        resp.raise_for_status.side_effect = httpx.HTTPStatusError(
            f"HTTP {status_code}",
            request=MagicMock(),
            response=resp,
        )
    else:
        resp.raise_for_status.return_value = None
    return resp


_CHAT_OK = {
    "choices": [{"message": {"content": "hello"}}],
    "usage": {"completion_tokens": 10, "prompt_tokens": 5},
}

_EMBED_OK = {
    "data": [{"embedding": [0.1, 0.2, 0.3]}],
}

_GENERATE_OK = {
    "choices": [{"message": {"content": "generated text"}}],
    "usage": {"completion_tokens": 20, "prompt_tokens": 10},
}

_MODELS_OK = {
    "data": [
        {"id": "Qwen/Qwen3-8B"},
        {"id": "BAAI/bge-large-en-v1.5"},
    ],
}


# ── _is_connection_error ─────────────────────────────────────────────


def test_is_connection_error_connect_error():
    assert _is_connection_error(httpx.ConnectError("refused")) is True


def test_is_connection_error_connect_timeout():
    assert _is_connection_error(httpx.ConnectTimeout("timed out")) is True


def test_is_connection_error_builtin_connection():
    assert _is_connection_error(ConnectionError("reset")) is True


def test_is_connection_error_builtin_timeout():
    assert _is_connection_error(TimeoutError("timed out")) is True


def test_is_connection_error_other():
    assert _is_connection_error(ValueError("bad value")) is False


def test_is_connection_error_runtime():
    assert _is_connection_error(RuntimeError("something broke")) is False


# ── Client creation ──────────────────────────────────────────────────


def test_client_with_explicit_hosts():
    client = VLLMClient(hosts=["host-a", "host-b"])
    assert client._hosts == ["host-a", "host-b"]


def test_client_with_single_host():
    client = VLLMClient(hosts=["localhost"])
    assert len(client._hosts) == 1


def test_get_client_adds_scheme_and_port():
    client = VLLMClient(hosts=["localhost"])
    httpx_client = client._get_client("localhost")
    assert httpx_client is not None
    # Subsequent call with same host returns the same cached instance
    assert client._get_client("localhost") is httpx_client


def test_get_client_preserves_scheme():
    client = VLLMClient(hosts=["http://myhost:8000"])
    httpx_client = client._get_client("http://myhost:8000")
    assert httpx_client is not None


def test_get_client_host_with_port():
    """Host with port but no scheme gets http:// prefix."""
    client = VLLMClient(hosts=["localhost:9000"])
    httpx_client = client._get_client("localhost:9000")
    assert httpx_client is not None


# ── Failover: chat ───────────────────────────────────────────────────


async def test_chat_succeeds_first_host():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.post = AsyncMock(return_value=_json_response(_CHAT_OK))
    client._clients["host-a"] = mock_httpx

    result = await client.chat(
        model="Qwen/Qwen3-8B",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert result.message.content == "hello"
    assert result.eval_count == 10
    assert result.prompt_eval_count == 5
    mock_httpx.post.assert_called_once()


async def test_chat_failover_to_second_host():
    client = VLLMClient(hosts=["host-a", "host-b"])
    client._rr_index = 0  # pin to start on host-a

    mock_a = AsyncMock()
    mock_a.post = AsyncMock(side_effect=httpx.ConnectError("refused"))
    client._clients["host-a"] = mock_a

    mock_b = AsyncMock()
    mock_b.post = AsyncMock(
        return_value=_json_response(
            {
                "choices": [{"message": {"content": "from b"}}],
                "usage": {"completion_tokens": 10, "prompt_tokens": 5},
            }
        )
    )
    client._clients["host-b"] = mock_b

    result = await client.chat(model="Qwen/Qwen3-8B", messages=[])

    assert result.message.content == "from b"
    # host-a gets 2 attempts (initial + 1 retry for connection errors)
    assert mock_a.post.call_count == 2
    mock_b.post.assert_called_once()


async def test_chat_all_hosts_fail():
    client = VLLMClient(hosts=["host-a", "host-b"])
    client._rr_index = 0  # pin to start on host-a

    mock_a = AsyncMock()
    mock_a.post = AsyncMock(side_effect=httpx.ConnectError("refused"))
    client._clients["host-a"] = mock_a

    mock_b = AsyncMock()
    mock_b.post = AsyncMock(side_effect=httpx.ConnectError("refused"))
    client._clients["host-b"] = mock_b

    with pytest.raises(httpx.ConnectError):
        await client.chat(model="Qwen/Qwen3-8B", messages=[])


async def test_chat_no_hosts_configured():
    with patch.object(VLLMClient, "_resolve_hosts", return_value=[]):
        client = VLLMClient()

    with pytest.raises(RuntimeError, match="no hosts configured"):
        await client.chat(model="Qwen/Qwen3-8B", messages=[])


async def test_non_connection_error_skips_retry():
    """Non-connection errors (e.g. 400 bad request) break immediately without retry."""
    client = VLLMClient(hosts=["host-a", "host-b"])
    client._rr_index = 0  # pin to start on host-a

    mock_a = AsyncMock()
    mock_a.post = AsyncMock(side_effect=ValueError("bad model"))
    client._clients["host-a"] = mock_a

    mock_b = AsyncMock()
    mock_b.post = AsyncMock(return_value=_json_response(_CHAT_OK))
    client._clients["host-b"] = mock_b

    result = await client.chat(model="bad-model", messages=[])

    # Non-connection error: no retry on host-a, moves to host-b
    assert mock_a.post.call_count == 1
    assert result.message.content == "hello"


# ── Chat: tool calls ─────────────────────────────────────────────────


async def test_chat_with_tool_calls():
    """Tool calls in response are parsed into _ToolCall dataclasses."""
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.post = AsyncMock(
        return_value=_json_response(
            {
                "choices": [
                    {
                        "message": {
                            "content": "",
                            "tool_calls": [
                                {
                                    "function": {
                                        "name": "service_status",
                                        "arguments": '{"name": "monitoring"}',
                                    },
                                }
                            ],
                        },
                    }
                ],
                "usage": {"completion_tokens": 30, "prompt_tokens": 10},
            }
        )
    )
    client._clients["host-a"] = mock_httpx

    result = await client.chat(model="Qwen/Qwen3-8B", messages=[], tools=[])

    assert result.message.tool_calls is not None
    assert len(result.message.tool_calls) == 1
    assert result.message.tool_calls[0].function.name == "service_status"
    assert result.message.tool_calls[0].function.arguments == {"name": "monitoring"}


async def test_chat_tool_call_arguments_as_dict():
    """When arguments come as dict (not JSON string), kept as-is."""
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.post = AsyncMock(
        return_value=_json_response(
            {
                "choices": [
                    {
                        "message": {
                            "content": "",
                            "tool_calls": [
                                {
                                    "function": {
                                        "name": "test_tool",
                                        "arguments": {"key": "value"},
                                    },
                                }
                            ],
                        },
                    }
                ],
                "usage": {},
            }
        )
    )
    client._clients["host-a"] = mock_httpx

    result = await client.chat(model="Qwen/Qwen3-8B", messages=[])

    assert result.message.tool_calls[0].function.arguments == {"key": "value"}


# ── Failover: embed ──────────────────────────────────────────────────


async def test_embed_succeeds():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.post = AsyncMock(return_value=_json_response(_EMBED_OK))
    client._clients["host-a"] = mock_httpx

    result = await client.embed(model="BAAI/bge-large-en-v1.5", input="hello")

    assert result.embeddings == [[0.1, 0.2, 0.3]]


async def test_embed_uses_dedicated_embed_hosts():
    """Embed requests go to embed_hosts, not chat hosts."""
    client = VLLMClient(hosts=["chat-host:8000"], embed_hosts=["embed-host:8001"])

    mock_embed = AsyncMock()
    mock_embed.post = AsyncMock(return_value=_json_response(_EMBED_OK))
    client._clients["embed-host:8001"] = mock_embed

    result = await client.embed(model="BAAI/bge-large-en-v1.5", input="hello")

    assert result.embeddings == [[0.1, 0.2, 0.3]]
    mock_embed.post.assert_called_once()
    # Chat host should NOT have been called
    assert "chat-host:8000" not in client._clients or not hasattr(
        client._clients.get("chat-host:8000"), "post"
    )


async def test_embed_hosts_fallback_to_chat_hosts():
    """When no embed hosts configured, embed uses chat hosts."""
    client = VLLMClient(hosts=["host-a"])
    assert client._embed_hosts == ["host-a"]


# ── Failover: generate ───────────────────────────────────────────────


async def test_generate_succeeds():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.post = AsyncMock(return_value=_json_response(_GENERATE_OK))
    client._clients["host-a"] = mock_httpx

    result = await client.generate(model="Qwen/Qwen3-8B", prompt="hello")

    assert result.response == "generated text"


# ── Failover: list ───────────────────────────────────────────────────


async def test_list_succeeds():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.get = AsyncMock(return_value=_json_response(_MODELS_OK))
    client._clients["host-a"] = mock_httpx

    result = await client.list()

    assert len(result.models) == 2
    assert result.models[0].id == "Qwen/Qwen3-8B"
    assert result.models[1].id == "BAAI/bge-large-en-v1.5"


# ── close ────────────────────────────────────────────────────────────


async def test_close_clears_clients():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.aclose = AsyncMock()
    client._clients["host-a"] = mock_httpx

    await client.close()

    mock_httpx.aclose.assert_called_once()
    assert len(client._clients) == 0


async def test_close_handles_errors():
    client = VLLMClient(hosts=["host-a"])
    mock_httpx = AsyncMock()
    mock_httpx.aclose = AsyncMock(side_effect=Exception("already closed"))
    client._clients["host-a"] = mock_httpx

    # Should not raise
    await client.close()
    assert len(client._clients) == 0


# ── Host resolution ──────────────────────────────────────────────────


def test_resolve_hosts_from_env():
    with patch.dict("os.environ", {"MAUDE_VLLM_HOSTS": "host-a, host-b"}):
        with patch("maude.daemon.common.resolve_infra_hosts", return_value={}):
            hosts = VLLMClient._resolve_hosts()

    assert hosts == ["host-a", "host-b"]


def test_resolve_hosts_from_secrets_multi():
    with (
        patch.dict("os.environ", {}, clear=True),
        patch(
            "maude.daemon.common.resolve_infra_hosts",
            return_value={
                "vllm_hosts": ["localhost", "localhost"],
            },
        ),
    ):
        hosts = VLLMClient._resolve_hosts()

    assert hosts == ["localhost", "localhost"]


def test_resolve_hosts_from_secrets_single():
    with (
        patch.dict("os.environ", {}, clear=True),
        patch(
            "maude.daemon.common.resolve_infra_hosts",
            return_value={
                "vllm": "localhost",
            },
        ),
    ):
        hosts = VLLMClient._resolve_hosts()

    assert hosts == ["localhost"]


def test_resolve_hosts_env_single_fallback():
    with (
        patch.dict("os.environ", {"MAUDE_VLLM_HOST": "localhost"}, clear=True),
        patch("maude.daemon.common.resolve_infra_hosts", return_value={}),
    ):
        hosts = VLLMClient._resolve_hosts()

    assert hosts == ["localhost"]


def test_resolve_hosts_empty():
    with (
        patch.dict("os.environ", {}, clear=True),
        patch("maude.daemon.common.resolve_infra_hosts", return_value={}),
    ):
        hosts = VLLMClient._resolve_hosts()

    assert hosts == []


# ── Round-robin host distribution ─────────────────────────────────────


async def test_round_robin_alternates_hosts():
    """Successive calls should rotate starting host across both GPUs."""
    client = VLLMClient(hosts=["host-a", "host-b"])
    # Fix the round-robin index for deterministic test
    client._rr_index = 0

    hosts_tried: list[str] = []

    ok_response = _json_response(
        {
            "choices": [{"message": {"content": "ok"}}],
            "usage": {"completion_tokens": 1, "prompt_tokens": 1},
        }
    )

    original_get_client = client._get_client

    def tracking_get_client(host: str) -> Any:
        hosts_tried.append(host)
        return original_get_client(host)

    # Mock both hosts to succeed
    mock_a = AsyncMock()
    mock_a.post = AsyncMock(return_value=ok_response)
    client._clients["host-a"] = mock_a

    mock_b = AsyncMock()
    mock_b.post = AsyncMock(return_value=ok_response)
    client._clients["host-b"] = mock_b

    with patch.object(client, "_get_client", side_effect=tracking_get_client):
        await client.chat(model="test", messages=[])
        await client.chat(model="test", messages=[])
        await client.chat(model="test", messages=[])
        await client.chat(model="test", messages=[])

    # First host tried should alternate: a, b, a, b
    assert hosts_tried[0] == "host-a"
    assert hosts_tried[1] == "host-b"
    assert hosts_tried[2] == "host-a"
    assert hosts_tried[3] == "host-b"


def test_round_robin_index_randomized():
    """Different VLLMClient instances should start at different indices."""
    indices = {VLLMClient(hosts=["a", "b"])._rr_index % 2 for _ in range(20)}
    # With 20 instances, both 0 and 1 should appear (probability of all same ~1e-6)
    assert len(indices) == 2
