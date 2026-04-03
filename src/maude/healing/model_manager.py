# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Per-Room model management.

Generates system prompts from knowledge files. With vLLM, system prompts
are passed at runtime in the messages array (no baked-in models).

VLLMModelManager provides model inventory (list, exists) via the
vLLM OpenAI-compatible API.

Usage:
    system = generate_system_prompt("my-service", Path("knowledge/"))
    manager = VLLMModelManager()
    models = await manager.list_models()
"""

import logging
from pathlib import Path
from typing import Any

from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)

_SCHEDULED_CHECK_INSTRUCTIONS = """\

## Scheduled Check Instructions
1. Call service_health or service_status to check current state.
2. If healthy, respond with a short summary. Do NOT call more tools.
3. If unhealthy, call 1-2 additional diagnostic tools, then summarize.
4. End your response with exactly:
<summary>one sentence</summary>
<outcome>resolved|failed|no_action</outcome>

Use at most 3 tool calls total. Always respond in English.
Do NOT escalate scheduled checks. Do NOT skip tool calls."""


def generate_system_prompt(project: str, knowledge_path: Path) -> str:
    """Build a system prompt from knowledge files.

    Reads ``identity.md`` and ``skills/*.md`` from the knowledge directory,
    appends scheduled check instructions.

    Args:
        project: Room project name (e.g., "my-service").
        knowledge_path: Path to the room's knowledge directory.

    Returns:
        System prompt text.
    """
    system_parts: list[str] = ["Always respond in English."]

    # Identity
    identity_file = knowledge_path / "identity.md"
    if identity_file.is_file():
        system_parts.append(identity_file.read_text().strip())
    else:
        system_parts.append(f"You are the {project} Room Agent.")

    # Skills
    skills_dir = knowledge_path / "skills"
    if skills_dir.is_dir():
        for skill_file in sorted(skills_dir.glob("*.md")):
            content = skill_file.read_text().strip()
            if content:
                system_parts.append(content)

    # Scheduled check instructions (always appended)
    system_parts.append(_SCHEDULED_CHECK_INSTRUCTIONS)

    return "\n\n".join(system_parts)


def resolve_knowledge_path(project: str, override: Path | None = None) -> Path:
    """Resolve the knowledge directory for a project.

    Searches multiple candidate paths on the control plane since projects are
    spread across ``platform/``, ``industrial/``, ``infrastructure/``.
    Tries ``.maude/`` before ``knowledge/`` per knowledge-schema.md v1.2.0.
    Falls back to the dependency graph's ``project`` field if present.

    Args:
        project: Room project name.
        override: Explicit knowledge path override.

    Returns:
        Path to the knowledge directory.
    """
    if override:
        return override

    base = Path.home() / "projects"

    # Build candidate list — .maude/ first, then knowledge/ fallback
    graph_prefix = None
    try:
        from maude.healing.dependencies import DependencyGraph

        graph = DependencyGraph()
        info = graph.room_info(project)
        if info.get("project"):
            graph_prefix = info["project"]
    except Exception:
        pass

    candidates: list[Path] = []
    search_bases = [project]
    if graph_prefix:
        search_bases.insert(0, graph_prefix)
    # Add restructured paths
    for prefix in ("platform", "industrial", "infrastructure", "apps"):
        search_bases.append(f"{prefix}/{project}")

    for sb in search_bases:
        candidates.append(base / sb / ".maude")
        candidates.append(base / sb / "knowledge")

    for candidate in candidates:
        if candidate.is_dir():
            return candidate

    # Fallback to convention (may not exist)
    return base / project / ".maude"


class VLLMModelManager:
    """Model inventory for vLLM-served models across GPU hosts.

    With vLLM, models are loaded at server startup (no runtime create/delete).
    System prompts are passed at runtime in the messages array.
    LoRA adapters are hot-loaded via the serving tools.

    Args:
        hosts: Explicit vLLM host list. If not provided,
            resolves from env vars / credentials via ``VLLMClient``.
    """

    def __init__(self, hosts: list[str] | None = None) -> None:
        self._vllm = VLLMClient(hosts=hosts)

    async def list_models(self) -> list[dict[str, Any]]:
        """List all models on the first reachable vLLM host."""
        try:
            response = await self._vllm.list()
            return [m.model_dump() for m in response.models]
        except Exception:
            logger.warning("Failed to list models", exc_info=True)
            return []

    async def model_exists(self, name: str) -> bool:
        """Check if a model is loaded on any vLLM host."""
        models = await self.list_models()
        return any(m.get("id", "") == name for m in models)

    async def close(self) -> None:
        await self._vllm.close()
