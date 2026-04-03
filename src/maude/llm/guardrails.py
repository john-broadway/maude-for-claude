"""NeMo Guardrails backend wrapper for Maude LLM routing.

Wraps any LLMBackend with NVIDIA NeMo Guardrails for input/output
filtering. Opt-in per room via config.yaml:

    llm:
      guardrails:
        enabled: true
        config_dir: ""  # empty = use built-in defaults

Degrades gracefully if nemoguardrails is not installed — logs a
warning and passes through without filtering.

Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Created: 2026-03-28 (MST)
"""

import logging
from pathlib import Path
from typing import Any

from maude.llm.types import LLMResponse

logger = logging.getLogger(__name__)

# Built-in guardrails config directory (ships with maude package)
_BUILTIN_CONFIG_DIR = Path(__file__).parent / "guardrails_config"

# Try importing nemoguardrails — optional dependency
try:
    from nemoguardrails import LLMRails, RailsConfig  # type: ignore[import-untyped]

    _HAS_NEMO = True
except ImportError:
    LLMRails = None  # type: ignore[assignment,misc]
    RailsConfig = None  # type: ignore[assignment,misc]
    _HAS_NEMO = False


class GuardrailsBackend:
    """Wraps an LLMBackend with NeMo Guardrails input/output rails.

    Implements the LLMBackend protocol so it can be used as a
    drop-in replacement anywhere a backend is expected.

    If nemoguardrails is not installed, passes through without filtering.
    """

    def __init__(
        self,
        backend: Any,
        *,
        config_dir: str = "",
        vllm_base_url: str = "",
        model: str = "",
    ) -> None:
        self._backend = backend
        self._rails: Any | None = None
        self._available = False

        if not _HAS_NEMO:
            logger.warning(
                "nemoguardrails not installed — guardrails disabled. "
                "Install with: pip install 'maude-claude[guardrails]'"
            )
            return

        # Resolve config directory
        config_path = Path(config_dir) if config_dir else _BUILTIN_CONFIG_DIR
        if not config_path.is_dir():
            logger.warning(
                "Guardrails config dir not found: %s — guardrails disabled",
                config_path,
            )
            return

        try:
            config = RailsConfig.from_path(str(config_path))  # type: ignore[union-attr]

            # Override model endpoint if provided
            if vllm_base_url and config.models:
                for m in config.models:
                    if hasattr(m, "parameters"):
                        m.parameters = m.parameters or {}
                        m.parameters["openai_api_base"] = vllm_base_url
                    if model and hasattr(m, "model"):
                        m.model = model

            self._rails = LLMRails(config)  # type: ignore[misc]
            self._available = True
            logger.info(
                "NeMo Guardrails enabled (config: %s, model: %s)",
                config_path,
                model or "default",
            )
        except Exception:
            logger.exception("Failed to initialize NeMo Guardrails — disabled")

    @property
    def available(self) -> bool:
        """Whether guardrails are active."""
        return self._available

    async def send(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 4096,
        system: str = "",
        tool_choice: str | None = None,
    ) -> LLMResponse:
        """Send messages through guardrails, then to the underlying backend.

        If guardrails are not available, passes through directly.
        If guardrails block the input, returns a refusal response
        without calling the underlying backend.
        """
        if not self._available:
            return await self._backend.send(messages, tools, max_tokens, system, tool_choice)

        # Extract the last user message for input rail check
        user_msg = ""
        for msg in reversed(messages):
            if msg.get("role") == "user":
                user_msg = msg.get("content", "")
                break

        # INPUT RAIL: Check user message
        rails = self._rails  # local ref for type narrowing
        if user_msg and rails is not None:
            try:
                input_result = await rails.generate_async(
                    messages=[{"role": "user", "content": user_msg}]
                )
                # If guardrails blocked the input, return the rail's response
                content = (
                    input_result.get("content", "")
                    if isinstance(input_result, dict)
                    else str(input_result)
                )
                if _is_blocked(content):
                    logger.info("Input rail blocked message: %s...", user_msg[:80])
                    return LLMResponse(
                        content=content,
                        model="guardrails",
                        stop_reason="guardrail_blocked",
                    )
            except Exception:
                logger.exception("Input rail check failed — passing through")

        # Call underlying backend
        response = await self._backend.send(messages, tools, max_tokens, system, tool_choice)

        # OUTPUT RAIL: Check model response
        if response.content and not response.tool_calls and rails is not None:
            try:
                output_check = await rails.generate_async(
                    messages=[
                        {"role": "user", "content": user_msg},
                        {"role": "assistant", "content": response.content},
                    ]
                )
                checked = (
                    output_check.get("content", "")
                    if isinstance(output_check, dict)
                    else str(output_check)
                )
                if _is_blocked(checked) and checked != response.content:
                    logger.info("Output rail filtered response")
                    return LLMResponse(
                        content=checked,
                        model=response.model,
                        tokens_used=response.tokens_used,
                        completion_tokens=response.completion_tokens,
                        stop_reason="guardrail_filtered",
                    )
            except Exception:
                logger.exception("Output rail check failed — passing through")

        return response

    async def close(self) -> None:
        """Close the underlying backend."""
        await self._backend.close()


def _is_blocked(content: str) -> bool:
    """Detect if guardrails produced a blocking/refusal response."""
    if not content:
        return False
    blockers = [
        "i'm not able to",
        "i cannot",
        "i can't",
        "not allowed",
        "blocked by guardrail",
        "sorry, i can't",
        "i apologize, but",
    ]
    lower = content.lower()
    return any(b in lower for b in blockers)


def wrap_if_enabled(
    backend: Any,
    config: dict[str, Any],
) -> Any:
    """Conditionally wrap a backend with guardrails if enabled in config.

    Args:
        backend: The LLMBackend to wrap.
        config: The full llm config dict from room_agent.

    Returns:
        GuardrailsBackend if enabled, otherwise the original backend.
    """
    gr_cfg = config.get("guardrails", {})
    if not gr_cfg.get("enabled"):
        return backend

    # Resolve vLLM URL for guardrails' own LLM calls
    vllm_cfg = config.get("vllm", {})
    base_url = vllm_cfg.get("base_url", "")
    if not base_url:
        try:
            from maude.daemon.common import resolve_infra_hosts

            hosts = resolve_infra_hosts().get("vllm_hosts", [])
            if hosts:
                base_url = f"http://{hosts[0]}:8000/v1"
        except Exception:
            pass

    return GuardrailsBackend(
        backend,
        config_dir=gr_cfg.get("config_dir", ""),
        vllm_base_url=base_url,
        model=vllm_cfg.get("model", ""),
    )
