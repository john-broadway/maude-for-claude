# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Multi-host vLLM client with Active-Active failover.

Drop-in replacement for OllamaClient using vLLM's OpenAI-compatible API.
Uses httpx.AsyncClient for connection pooling and proper async HTTP.

Response types are compatible with the Ollama SDK's attribute access
patterns so consumers need only rename their import.

Usage:
    client = VLLMClient()                         # resolve hosts from secrets.yaml
    client = VLLMClient(hosts=["localhost"])    # explicit hosts

    resp = await client.chat(model="Qwen/Qwen3-8B", messages=[...])
    emb  = await client.embed(model="BAAI/bge-large-en-v1.5", input="hello")
    await client.close()
"""

import asyncio
import json
import logging
import os
import random
import re
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_DEFAULT_PORT = 8000
_DEFAULT_TIMEOUT = 120.0


# ── Response types (compatible with Ollama SDK attribute access) ──────


@dataclass
class _Function:
    name: str = ""
    arguments: dict[str, Any] = field(default_factory=dict)


@dataclass
class _ToolCall:
    function: _Function = field(default_factory=_Function)


@dataclass
class _ChatMessage:
    content: str | None = None
    tool_calls: list[_ToolCall] | None = None


@dataclass
class _ChatResponse:
    """Compatible with Ollama SDK ChatResponse attribute access."""

    message: _ChatMessage = field(default_factory=_ChatMessage)
    eval_count: int = 0
    prompt_eval_count: int = 0


@dataclass
class _EmbedResponse:
    """Compatible with Ollama SDK EmbedResponse.embeddings access."""

    embeddings: list[list[float]] = field(default_factory=list)


@dataclass
class _GenerateResponse:
    """Compatible with Ollama SDK GenerateResponse.response access."""

    response: str = ""


@dataclass
class _ModelInfo:
    id: str = ""

    def model_dump(self) -> dict[str, Any]:
        return {"id": self.id}


@dataclass
class _ModelsResponse:
    models: list[_ModelInfo] = field(default_factory=list)


class VLLMError(Exception):
    """Raised when vLLM API returns an error."""


class VLLMClient:
    """Multi-host vLLM client.

    Args:
        hosts: Chat/generate host list (IP or IP:port, no scheme needed).
            If not provided, resolves from MAUDE_VLLM_HOSTS env var
            or secrets.yaml via ``resolve_infra_hosts()``.
        embed_hosts: Embed host list for /v1/embeddings requests.
            If not provided, resolves from MAUDE_EMBEDDING_HOST env var.
            Falls back to ``hosts`` when not set.
    """

    def __init__(
        self,
        hosts: list[str] | None = None,
        embed_hosts: list[str] | None = None,
    ) -> None:
        self._hosts = hosts or self._resolve_hosts()
        if embed_hosts:
            self._embed_hosts = embed_hosts
        elif hosts:
            # Explicit hosts override — use same for embed
            self._embed_hosts = self._hosts
        else:
            self._embed_hosts = self._resolve_embed_hosts() or self._hosts
        self._clients: dict[str, httpx.AsyncClient] = {}
        self._last_used: dict[str, float] = {}
        # Round-robin: randomize start so 19 rooms don't all hit the same host first
        self._rr_index: int = random.randint(0, 999)

    @staticmethod
    def _resolve_hosts() -> list[str]:
        """Resolve vLLM chat hosts from env vars and credentials."""
        from maude.daemon.common import resolve_infra_hosts

        infra = resolve_infra_hosts()

        # Multi-host (env: comma-sep MAUDE_VLLM_HOSTS)
        env_hosts = os.environ.get("MAUDE_VLLM_HOSTS", "")
        if env_hosts:
            return [h.strip() for h in env_hosts.split(",") if h.strip()]

        # Multi-host from secrets.yaml
        vllm_hosts: list[str] = infra.get("vllm_hosts", [])
        if vllm_hosts:
            return list(vllm_hosts)

        # Single host (env > secrets)
        single = os.environ.get("MAUDE_VLLM_HOST", "") or infra.get("vllm", "")
        if single:
            return [single]

        return []

    @staticmethod
    def _resolve_embed_hosts() -> list[str]:
        """Resolve dedicated embedding hosts from env var or infra config."""
        env_hosts = os.environ.get("MAUDE_EMBEDDING_HOST", "")
        if env_hosts:
            return [h.strip() for h in env_hosts.split(",") if h.strip()]
        from maude.daemon.common import resolve_infra_hosts

        return list(resolve_infra_hosts().get("embedder_hosts", []))

    _CLIENT_TTL = 1800  # evict clients unused for 30 minutes

    def _evict_stale_clients(self) -> None:
        """Close and remove httpx clients unused for more than _CLIENT_TTL seconds."""
        now = time.monotonic()
        stale = [host for host, ts in self._last_used.items() if now - ts > self._CLIENT_TTL]
        for host in stale:
            client = self._clients.pop(host, None)
            self._last_used.pop(host, None)
            if client:
                # Schedule async close without blocking the sync caller
                try:
                    asyncio.get_running_loop().create_task(client.aclose())
                except RuntimeError:
                    pass  # No running loop — client will be GC'd

    def _get_client(self, host: str) -> httpx.AsyncClient:
        """Lazy-create a cached httpx client for a host, evicting stale ones."""
        self._evict_stale_clients()
        if host not in self._clients:
            if "://" in host:
                base_url = host.rstrip("/")
            else:
                # Add scheme and default port if no port specified
                if ":" in host:
                    base_url = f"http://{host}"
                else:
                    base_url = f"http://{host}:{_DEFAULT_PORT}"
            self._clients[host] = httpx.AsyncClient(
                base_url=base_url,
                timeout=httpx.Timeout(_DEFAULT_TIMEOUT),
            )
        self._last_used[host] = time.monotonic()
        return self._clients[host]

    # ── Failover methods ─────────────────────────────────────────

    async def chat(self, **kwargs: Any) -> _ChatResponse:
        """Send a chat completion request with multi-host failover.

        Accepts Ollama-style kwargs for backward compatibility:
        ``model``, ``messages``, ``tools``, ``stream`` (ignored),
        ``options`` (extracted to top-level params).
        """
        return await self._try_hosts("chat", **kwargs)

    async def embed(self, **kwargs: Any) -> _EmbedResponse:
        """Get embeddings with multi-host failover.

        Args (via kwargs):
            model: Embedding model name.
            input: Text or list of texts to embed.
        """
        return await self._try_hosts("embed", **kwargs)

    async def generate(self, **kwargs: Any) -> _GenerateResponse:
        """Generate completion with multi-host failover.

        Wraps chat completions with a single user message
        for backward compatibility with Ollama generate().
        """
        return await self._try_hosts("generate", **kwargs)

    async def list(self) -> _ModelsResponse:
        """List models from first reachable host."""
        return await self._try_hosts("list")

    # ── Core loop ────────────────────────────────────────────────

    async def _try_hosts(self, method: str, **kwargs: Any) -> Any:
        """Try hosts round-robin with failover and 1 retry on connection errors."""
        hosts = self._embed_hosts if method == "embed" else self._hosts
        if not hosts:
            raise RuntimeError(f"VLLMClient: no hosts configured for {method}")

        # Round-robin: rotate starting host each call
        n = len(hosts)
        start = self._rr_index % n
        self._rr_index += 1
        ordered = hosts[start:] + hosts[:start]

        last_exc: Exception | None = None
        for host in ordered:
            client = self._get_client(host)
            for attempt in range(2):
                try:
                    return await self._dispatch(client, method, **kwargs)
                except Exception as exc:
                    last_exc = exc
                    is_connect = _is_connection_error(exc)
                    if is_connect and attempt == 0:
                        logger.info(
                            "VLLMClient: %s on %s failed (connect), retrying in 2s",
                            method,
                            host,
                        )
                        await asyncio.sleep(2)
                        continue
                    if is_connect:
                        logger.warning(
                            "VLLMClient: %s on %s failed after retry, trying next",
                            method,
                            host,
                        )
                    else:
                        logger.warning(
                            "VLLMClient: %s on %s failed: %s",
                            method,
                            host,
                            exc,
                        )
                    break

        raise last_exc or RuntimeError(f"VLLMClient: all hosts failed for {method}")

    async def _dispatch(
        self,
        client: httpx.AsyncClient,
        method: str,
        **kwargs: Any,
    ) -> Any:
        """Route a method call to the appropriate vLLM API endpoint."""
        if method == "chat":
            return await self._do_chat(client, **kwargs)
        elif method == "embed":
            return await self._do_embed(client, **kwargs)
        elif method == "generate":
            return await self._do_generate(client, **kwargs)
        elif method == "list":
            return await self._do_list(client)
        else:
            raise ValueError(f"VLLMClient: unknown method {method}")

    async def _do_chat(self, client: httpx.AsyncClient, **kwargs: Any) -> _ChatResponse:
        """POST /v1/chat/completions with Ollama-compatible kwargs."""
        # Extract Ollama-style options dict if present
        options = kwargs.pop("options", {})
        kwargs.pop("stream", None)  # vLLM doesn't use stream param here

        payload: dict[str, Any] = {
            "model": kwargs.get("model", ""),
            "messages": kwargs.get("messages", []),
        }

        # Map Ollama options to OpenAI params
        if "num_predict" in options:
            payload["max_tokens"] = options["num_predict"]
        if "temperature" in options:
            payload["temperature"] = options["temperature"]

        # Direct params override options
        if "max_tokens" in kwargs:
            payload["max_tokens"] = kwargs["max_tokens"]
        if "temperature" in kwargs:
            payload["temperature"] = kwargs["temperature"]

        if kwargs.get("tools"):
            payload["tools"] = kwargs["tools"]
        if kwargs.get("tool_choice"):
            payload["tool_choice"] = kwargs["tool_choice"]

        resp = await client.post("/v1/chat/completions", json=payload)

        # Handle context overflow: vLLM returns 400 when prompt + max_tokens
        # exceeds the model's context window. Cap max_tokens and retry.
        if resp.status_code == 400 and payload.get("max_tokens"):
            capped = self._cap_max_tokens_from_error(resp, payload)
            if capped:
                resp = await client.post("/v1/chat/completions", json=payload)
            elif capped is None:
                raise VLLMError("Context window full — not enough room for completion")

        if resp.status_code == 404:
            body = resp.text[:200]
            raise VLLMError(f"Model not found (404): requested '{payload.get('model')}' — {body}")
        resp.raise_for_status()
        data = resp.json()

        # Parse OpenAI-format response into compatible types
        choice = data.get("choices", [{}])[0] if data.get("choices") else {}
        msg_data = choice.get("message", {})
        usage = data.get("usage", {})

        tool_calls: list[_ToolCall] | None = None
        raw_tcs = msg_data.get("tool_calls")
        if raw_tcs:
            tool_calls = []
            for tc in raw_tcs:
                fn = tc.get("function", {})
                args = fn.get("arguments", {})
                # vLLM returns arguments as JSON string; parse to dict
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except (json.JSONDecodeError, TypeError):
                        args = {}
                tool_calls.append(
                    _ToolCall(
                        function=_Function(name=fn.get("name", ""), arguments=args),
                    )
                )

        return _ChatResponse(
            message=_ChatMessage(
                content=msg_data.get("content"),
                tool_calls=tool_calls,
            ),
            eval_count=usage.get("completion_tokens", 0),
            prompt_eval_count=usage.get("prompt_tokens", 0),
        )

    async def _do_embed(self, client: httpx.AsyncClient, **kwargs: Any) -> _EmbedResponse:
        """POST /v1/embeddings."""
        model = kwargs.get("model", "")
        input_text = kwargs.get("input", "")

        payload: dict[str, Any] = {
            "model": model,
            "input": input_text,
            "truncate_prompt_tokens": 512,
        }
        resp = await client.post("/v1/embeddings", json=payload)
        resp.raise_for_status()
        data = resp.json()

        # Convert OpenAI format to Ollama-compatible: response.embeddings = [[...], ...]
        embeddings = [item["embedding"] for item in data.get("data", [])]
        return _EmbedResponse(embeddings=embeddings)

    async def _do_generate(
        self,
        client: httpx.AsyncClient,
        **kwargs: Any,
    ) -> _GenerateResponse:
        """Wrap chat completions to emulate Ollama generate()."""
        model = kwargs.get("model", "")
        prompt = kwargs.get("prompt", "")

        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
        }
        resp = await client.post("/v1/chat/completions", json=payload)
        resp.raise_for_status()
        data = resp.json()

        content = ""
        choices = data.get("choices", [])
        if choices:
            content = choices[0].get("message", {}).get("content", "") or ""

        return _GenerateResponse(response=content)

    async def _do_list(self, client: httpx.AsyncClient) -> _ModelsResponse:
        """GET /v1/models."""
        resp = await client.get("/v1/models")
        resp.raise_for_status()
        data = resp.json()

        models = [_ModelInfo(id=m.get("id", "")) for m in data.get("data", [])]
        return _ModelsResponse(models=models)

    @staticmethod
    def _cap_max_tokens_from_error(
        resp: httpx.Response,
        payload: dict[str, Any],
    ) -> bool | None:
        """Parse a 400 context overflow error and cap max_tokens in-place.

        Returns:
            True if payload was updated (caller should retry).
            False if the error is not a context overflow (caller should raise).
            None if context is full with no room for completion.
        """
        try:
            body = resp.json()
            msg = body.get("message", "") or body.get("detail", "") or str(body)
        except Exception:
            return False

        if "max_tokens" not in msg and "max_completion_tokens" not in msg:
            return False

        prompt_match = re.search(r"has (\d+) input tokens", msg)
        ctx_match = re.search(r"context length is (\d+)", msg)
        if not prompt_match or not ctx_match:
            return False

        prompt_tokens = int(prompt_match.group(1))
        ctx_len = int(ctx_match.group(1))
        available = ctx_len - prompt_tokens - 32  # small safety margin

        if available < 64:
            logger.warning(
                "VLLMClient: context full — %d prompt tokens, %d available",
                prompt_tokens,
                available,
            )
            return None

        old = payload["max_tokens"]
        payload["max_tokens"] = available
        logger.warning(
            "VLLMClient: max_tokens %d exceeds available %d (prompt=%d, ctx=%d), capping",
            old,
            available,
            prompt_tokens,
            ctx_len,
        )
        return True

    async def close(self) -> None:
        """Close all cached httpx clients."""
        for client in self._clients.values():
            try:
                await client.aclose()
            except Exception:
                pass
        self._clients.clear()


def _is_connection_error(exc: Exception) -> bool:
    """Check if an exception is a connection/timeout error."""
    return isinstance(
        exc,
        (
            httpx.ConnectError,
            httpx.ConnectTimeout,
            ConnectionError,
            TimeoutError,
        ),
    )
