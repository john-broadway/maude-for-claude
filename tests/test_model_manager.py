# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for model_manager — system prompt generation + VLLMModelManager."""

from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from maude.healing.model_manager import (
    VLLMModelManager,
    generate_system_prompt,
    resolve_knowledge_path,
)
from maude.llm.vllm import _ModelInfo, _ModelsResponse

# ── System prompt generation ──────────────────────────────────────


def test_generate_system_prompt_with_identity_and_skills(tmp_path: Path):
    """System prompt includes identity, skills, and instructions."""
    knowledge = tmp_path / "knowledge"
    knowledge.mkdir()
    (knowledge / "identity.md").write_text("You are the Collector Agent.")
    skills = knowledge / "skills"
    skills.mkdir()
    (skills / "health.md").write_text("## Health\nCheck endpoints.")

    system = generate_system_prompt("my-service", knowledge)

    assert "Collector Agent" in system
    assert "## Health" in system
    assert "Scheduled Check Instructions" in system


def test_generate_system_prompt_fallback_identity(tmp_path: Path):
    """Missing identity.md uses fallback."""
    knowledge = tmp_path / "knowledge"
    knowledge.mkdir()

    system = generate_system_prompt("monitoring", knowledge)

    assert "monitoring Room Agent" in system


# ── Knowledge path resolution ─────────────────────────────────────


def test_resolve_knowledge_path_searches_candidates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
):
    """Resolves knowledge from candidate directories when no override."""
    # Simulate ~/projects/infrastructure/myproject/knowledge/ existing
    knowledge = tmp_path / "projects" / "infrastructure" / "myproject" / "knowledge"
    knowledge.mkdir(parents=True)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    # Patch out DependencyGraph so it doesn't interfere
    monkeypatch.setattr(
        "maude.healing.model_manager.DependencyGraph",
        None,
        raising=False,
    )
    path = resolve_knowledge_path("myproject")
    assert path == knowledge


def test_resolve_knowledge_path_prefers_maude_over_knowledge(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
):
    """Prefers .maude/ over knowledge/ when both exist."""
    maude_dir = tmp_path / "projects" / "myproject" / ".maude"
    knowledge = tmp_path / "projects" / "myproject" / "knowledge"
    maude_dir.mkdir(parents=True)
    knowledge.mkdir(parents=True)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    path = resolve_knowledge_path("myproject")
    assert path == maude_dir


def test_resolve_knowledge_path_falls_back_to_knowledge(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
):
    """Falls back to knowledge/ when .maude/ doesn't exist."""
    knowledge = tmp_path / "projects" / "myproject" / "knowledge"
    knowledge.mkdir(parents=True)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    path = resolve_knowledge_path("myproject")
    assert path == knowledge


def test_resolve_knowledge_path_fallback(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Falls back to convention path when no candidate exists."""
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    path = resolve_knowledge_path("nonexistent")
    assert path == tmp_path / "projects" / "nonexistent" / ".maude"


def test_resolve_knowledge_path_override(tmp_path: Path):
    """Override path is used when provided."""
    custom = tmp_path / "custom" / "knowledge"
    path = resolve_knowledge_path("my-service", override=custom)
    assert path == custom


# ── VLLMModelManager ─────────────────────────────────────────────


@pytest.fixture
def manager() -> VLLMModelManager:
    return VLLMModelManager(hosts=["host1", "host2"])


async def test_list_models(manager: VLLMModelManager):
    """List models from first reachable host."""
    manager._vllm.list = AsyncMock(return_value=_ModelsResponse(
        models=[
            _ModelInfo(id="Qwen/Qwen3-8B"),
            _ModelInfo(id="BAAI/bge-large-en-v1.5"),
        ],
    ))

    models = await manager.list_models()

    assert len(models) == 2
    assert models[0]["id"] == "Qwen/Qwen3-8B"
    assert models[1]["id"] == "BAAI/bge-large-en-v1.5"


async def test_list_models_all_hosts_fail(manager: VLLMModelManager):
    """All hosts fail → empty list."""
    manager._vllm.list = AsyncMock(side_effect=RuntimeError("All vLLM hosts failed"))

    models = await manager.list_models()

    assert models == []


async def test_model_exists_true(manager: VLLMModelManager):
    """model_exists returns True when model is in the list."""
    manager._vllm.list = AsyncMock(return_value=_ModelsResponse(
        models=[_ModelInfo(id="Qwen/Qwen3-8B")],
    ))

    assert await manager.model_exists("Qwen/Qwen3-8B") is True


async def test_model_exists_false(manager: VLLMModelManager):
    """model_exists returns False when model is not found."""
    manager._vllm.list = AsyncMock(return_value=_ModelsResponse(
        models=[_ModelInfo(id="Qwen/Qwen3-8B")],
    ))

    assert await manager.model_exists("nonexistent-model") is False


async def test_model_exists_empty_list(manager: VLLMModelManager):
    """model_exists returns False when list_models returns empty."""
    manager._vllm.list = AsyncMock(side_effect=RuntimeError("down"))

    assert await manager.model_exists("Qwen/Qwen3-8B") is False


async def test_manager_url_resolution():
    """Manager resolves hosts via VLLMClient when no explicit hosts."""
    with patch(
        "maude.llm.vllm.VLLMClient._resolve_hosts",
        return_value=["localhost", "localhost"],
    ):
        mgr = VLLMModelManager()

    assert "localhost" in mgr._vllm._hosts
    assert "localhost" in mgr._vllm._hosts


async def test_manager_close(manager: VLLMModelManager):
    """close() delegates to VLLMClient."""
    manager._vllm.close = AsyncMock()
    await manager.close()
    manager._vllm.close.assert_awaited_once()
