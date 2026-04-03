"""LLM backend abstraction for Room Agents.

Provides a unified interface for vLLM backends with automatic
multi-host failover. The Room Agent calls LLMRouter.send() and gets
a response regardless of which host is available.

Multi-tier model routing (L1-L4):
    L1 = Per-room vLLM model (auto-resolved from fleet) — the primary backend
    L2 = Shared vLLM model (e.g., Qwen3-14B) — for complex reasoning
    L3 = Heavyweight GPU vLLM model (e.g., Qwen3-32B) — specialist
    L4 = T4 escalation (reserved)

Usage:
    router = LLMRouter.from_config(config_dict)
    response = await router.send(messages, tools, max_tokens=4096)
    response = await router.send_complex(messages, tools, max_tokens=8192)
    if response:
        # response.content, response.tool_calls, response.model, response.tokens_used
"""

import asyncio
import json
import logging
import random
from typing import Any

import httpx

from maude.llm.types import LLMBackend, LLMResponse, ModelTier, ToolCall
from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)

# Re-export types for consumers importing from this module
__all__ = [
    "LLMBackend",
    "LLMResponse",
    "LLMRouter",
    "ModelTier",
    "ToolCall",
    "VLLMBackend",
]


class VLLMBackend:
    """vLLM backend using the OpenAI-compatible API with multi-host failover.

    Wraps ``VLLMClient`` for Active-Active GPU failover.
    A/B test model selection is a routing concern handled here,
    not in the client.
    """

    def __init__(
        self,
        base_url: str = "",
        base_urls: list[str] | None = None,
        model: str = "",
        temperature: float = 0.2,
        challenger: str = "",
        challenger_ratio: float = 0.0,
    ) -> None:
        self._preferred_model = model
        self.model = model
        self._resolved = False
        self.challenger = challenger
        self.challenger_ratio = challenger_ratio
        self.temperature = temperature

        # Build host list for VLLMClient
        if base_urls:
            hosts = [u.rstrip("/") for u in base_urls]
        elif base_url:
            hosts = [base_url.rstrip("/")]
        else:
            hosts = None  # let VLLMClient resolve
        self._vllm = VLLMClient(hosts=hosts)

    async def _resolve_model(self) -> None:
        """Probe /v1/models and resolve the actual model to use.

        If the configured model is available, use it. Otherwise, use
        whatever model is loaded on the fleet. Called once on first send().
        """
        if self._resolved:
            return
        self._resolved = True
        try:
            resp = await self._vllm.list()
            available = [m.id for m in resp.models]
            if not available:
                logger.warning(
                    "vLLM fleet returned no models — using configured '%s'", self._preferred_model
                )
                return
            if self._preferred_model in available:
                logger.info("vLLM model confirmed: %s", self._preferred_model)
                return
            # Configured model not available — use first available
            self.model = available[0]
            logger.warning(
                "vLLM model '%s' not found — resolved to '%s' (available: %s)",
                self._preferred_model,
                self.model,
                ", ".join(available),
            )
        except Exception:
            logger.warning(
                "vLLM model probe failed — using configured '%s'",
                self._preferred_model,
                exc_info=True,
            )

    async def send(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
        tool_choice: str | None = None,
    ) -> LLMResponse:
        await self._resolve_model()
        # A/B test: randomly select challenger model when configured
        active_model = self.model
        if self.challenger and random.random() < self.challenger_ratio:
            active_model = self.challenger

        # Build messages list
        oai_messages: list[dict[str, Any]] = []
        if system:
            oai_messages.append({"role": "system", "content": system})
        for msg in messages:
            oai_messages.append(_to_openai_message(msg))

        kwargs: dict[str, Any] = {
            "model": active_model,
            "messages": oai_messages,
            "max_tokens": max_tokens,
            "temperature": self.temperature,
        }
        if tools:
            kwargs["tools"] = _to_openai_tools(tools)
        if tool_choice and tools:
            kwargs["tool_choice"] = tool_choice

        response = await self._vllm.chat(**kwargs)

        # Parse response (VLLMClient returns compatible types)
        message = response.message
        content = message.content or ""
        tool_calls: list[ToolCall] = []

        for i, tc in enumerate(message.tool_calls or []):
            tool_calls.append(
                ToolCall(
                    id=f"vllm_{i}",
                    name=tc.function.name or "",
                    arguments=tc.function.arguments or {},
                )
            )

        completion = response.eval_count or 0
        tokens = completion + (response.prompt_eval_count or 0)

        return LLMResponse(
            content=content,
            tool_calls=tool_calls,
            model=active_model,
            tokens_used=tokens,
            completion_tokens=completion,
            stop_reason="tool_use" if tool_calls else "end_turn",
        )

    async def close(self) -> None:
        await self._vllm.close()


class LLMRouter:
    """Routes LLM requests to available backends with fallback.

    Multi-tier chain:
        send()          → primary (L1) → fallback (L4) → None
        send_complex()  → complex (L2) → specialist (L3) → primary (L1) → None
        send_to_fallback() → fallback (L4) → None
    """

    def __init__(
        self,
        primary: LLMBackend | None = None,
        fallback: LLMBackend | None = None,
        complex: LLMBackend | None = None,
        specialist: LLMBackend | None = None,
    ) -> None:
        self.primary = primary
        self.fallback = fallback
        self.complex = complex
        self.specialist = specialist

    @classmethod
    def from_config(
        cls,
        config: dict[str, Any],
        credentials: dict[str, Any] | None = None,
    ) -> "LLMRouter":
        """Build router from config dict.

        Args:
            config: LLM config section from room_agent config.
            credentials: Unused, kept for backward compatibility.

        Config keys:
            vllm: Primary (L1) vLLM backend config.
            complex: L2 complex reasoning backend (larger shared model).
            specialist: L3 specialist backend (heavyweight GPU).
            fallback: L4 fallback backend (T4 escalation target).
        """
        primary: LLMBackend | None = None
        fallback_backend: LLMBackend | None = None
        complex_backend: LLMBackend | None = None
        specialist_backend: LLMBackend | None = None

        # Build primary (L1) vLLM backend
        vllm_cfg = config.get("vllm", {})
        ab_cfg = vllm_cfg.get("ab_test", {})
        if vllm_cfg.get("model"):
            primary = VLLMBackend(
                base_url=vllm_cfg.get("base_url", ""),
                model=vllm_cfg.get("model", ""),
                temperature=float(vllm_cfg.get("temperature", 0.2)),
                challenger=ab_cfg.get("challenger", ""),
                challenger_ratio=float(ab_cfg.get("ratio", 0.0)),
            )

        # Build complex (L2) backend — shared larger model
        complex_cfg = config.get("complex", {})
        if complex_cfg.get("model"):
            complex_backend = VLLMBackend(
                base_url=complex_cfg.get("base_url", ""),
                base_urls=complex_cfg.get("base_urls"),
                model=complex_cfg["model"],
                temperature=float(complex_cfg.get("temperature", 0.3)),
            )

        # Build specialist (L3) backend — heavyweight GPU
        specialist_cfg = config.get("specialist", {})
        if specialist_cfg.get("model"):
            specialist_backend = VLLMBackend(
                base_url=specialist_cfg.get("base_url", ""),
                base_urls=specialist_cfg.get("base_urls"),
                model=specialist_cfg["model"],
                temperature=float(specialist_cfg.get("temperature", 0.3)),
            )

        # Build fallback (L4) backend — T4 escalation target
        fallback_cfg = config.get("fallback", {})
        if fallback_cfg.get("model"):
            fallback_backend = VLLMBackend(
                base_url=fallback_cfg.get("base_url", ""),
                base_urls=fallback_cfg.get("base_urls"),
                model=fallback_cfg["model"],
                temperature=float(fallback_cfg.get("temperature", 0.3)),
            )

        # Wrap primary with guardrails if enabled
        if primary is not None:
            from maude.llm.guardrails import wrap_if_enabled

            primary = wrap_if_enabled(primary, config)

        return cls(
            primary=primary,
            fallback=fallback_backend,
            complex=complex_backend,
            specialist=specialist_backend,
        )

    @property
    def can_escalate(self) -> bool:
        """Whether a T4 escalation backend is available."""
        return self.fallback is not None

    async def send_to_fallback(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
    ) -> LLMResponse | None:
        """Send directly to the fallback backend (T4 escalation).

        Unlike send(), this skips the primary and goes straight to fallback.
        Returns None if no fallback is configured.
        """
        if self.fallback is None:
            logger.warning("T4 escalation requested but no fallback backend configured")
            return None
        try:
            return await self.fallback.send(messages, tools, max_tokens, system)
        except Exception:
            logger.error("T4 escalation to fallback failed", exc_info=True)
            return None

    async def send_complex(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 8192,
        system: str = "",
    ) -> LLMResponse | None:
        """Send to higher-tier backends for complex reasoning.

        Tries: complex (L2) → specialist (L3) → primary (L1) → None.
        Used when the agent needs more capability (e.g., iteration > 3).
        """
        for backend in [self.complex, self.specialist, self.primary]:
            if backend is None:
                continue
            name = type(backend).__name__
            try:
                return await self._send_with_retry(backend, messages, tools, max_tokens, system)
            except Exception:
                logger.warning("Complex backend %s failed, trying next tier", name, exc_info=True)
                continue

        logger.error("All complex backends failed — no response available")
        return None

    async def send(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
        tool_choice: str | None = None,
    ) -> LLMResponse | None:
        """Send a request to the best available backend.

        Retries with exponential backoff on rate limit (429) errors before
        falling through to the next backend. Returns None if all backends fail.
        """
        for backend in [self.primary, self.fallback]:
            if backend is None:
                continue
            name = type(backend).__name__
            try:
                return await self._send_with_retry(
                    backend,
                    messages,
                    tools,
                    max_tokens,
                    system,
                    tool_choice=tool_choice,
                )
            except Exception:
                logger.warning("LLM backend %s failed, trying fallback", name, exc_info=True)
                continue

        logger.error("All LLM backends failed — no response available")
        return None

    async def _send_with_retry(
        self,
        backend: LLMBackend,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
        max_tokens: int,
        system: str,
        max_retries: int = 3,
        tool_choice: str | None = None,
    ) -> LLMResponse:
        """Send with exponential backoff on rate limit errors."""
        last_exc: Exception | None = None
        for attempt in range(max_retries + 1):
            try:
                return await backend.send(
                    messages,
                    tools,
                    max_tokens,
                    system,
                    tool_choice=tool_choice,
                )
            except Exception as exc:
                if not _is_rate_limit(exc) or attempt == max_retries:
                    raise
                last_exc = exc
                delay = 2 ** (attempt + 1) + random.uniform(0, 1)  # 2-3s, 4-5s, 8-9s
                name = type(backend).__name__
                logger.info(
                    "Rate limited on %s, retry %d/%d in %ds",
                    name,
                    attempt + 1,
                    max_retries,
                    delay,
                )
                await asyncio.sleep(delay)
        # Unreachable, but satisfies type checker
        raise last_exc  # type: ignore[misc]

    async def close(self) -> None:
        for backend in [self.primary, self.fallback, self.complex, self.specialist]:
            if backend is not None:
                try:
                    await backend.close()
                except Exception:
                    pass


def _is_rate_limit(exc: Exception) -> bool:
    """Check if an exception is a rate limit (429) error."""
    if type(exc).__name__ == "RateLimitError":
        return True
    if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code == 429:
        return True
    return False


def _to_openai_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Convert generic tool schemas to OpenAI-compatible format."""
    return [
        {
            "type": "function",
            "function": {
                "name": t["name"],
                "description": t.get("description", ""),
                "parameters": t.get("parameters", {"type": "object", "properties": {}}),
            },
        }
        for t in tools
    ]


def _stringify_args(args: Any) -> str:
    """Ensure tool call arguments are a JSON string for vLLM hermes parser."""
    if isinstance(args, dict):
        return json.dumps(args)
    if isinstance(args, str):
        return args
    return "{}"


def _to_openai_message(msg: dict[str, Any]) -> dict[str, Any]:
    """Convert a generic message to OpenAI-compatible format.

    Handles tool_result messages which vLLM expects as role=tool with
    tool_call_id. vLLM hermes parser requires arguments as JSON strings.
    """
    role = msg.get("role", "user")
    content = msg.get("content", "")

    if role == "tool":
        return {"role": "tool", "content": content, "tool_call_id": msg.get("tool_call_id", "")}

    # Claude-style tool_result: role=user with content block list containing
    # {"type": "tool_result", "tool_use_id": ..., "content": ...}
    # Convert to vLLM's expected role=tool format with tool_call_id.
    if role == "user" and isinstance(content, list):
        blocks = content
        if blocks and blocks[0].get("type") == "tool_result":
            return {
                "role": "tool",
                "content": blocks[0].get("content", ""),
                "tool_call_id": blocks[0].get("tool_use_id", ""),
            }

    if role == "assistant" and msg.get("tool_calls"):
        return {
            "role": "assistant",
            "content": content,
            "tool_calls": [
                {
                    "id": tc.get("id", ""),
                    "type": "function",
                    "function": {
                        "name": tc.get("name", ""),
                        "arguments": _stringify_args(tc.get("arguments", {})),
                    },
                }
                for tc in msg["tool_calls"]
            ],
        }

    return {"role": role, "content": content}
