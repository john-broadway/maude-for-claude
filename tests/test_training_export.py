# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.runtime.training_export — pure conversion functions."""

import json
from unittest.mock import AsyncMock

import pytest

from maude.healing.training.export import (
    DEFAULT_SYNTHETIC_RATIO,
    build_system_prompt,
    check_conversation_english,
    export_training_data,
    is_english,
    mix_synthetic,
    normalize_messages,
    row_to_training_example,
)

# ── normalize_messages ───────────────────────────────────────────


def test_normalize_basic_messages():
    """User/assistant messages pass through unchanged."""
    conv = [
        {"role": "user", "content": "check service health"},
        {"role": "assistant", "content": "Service is healthy."},
    ]
    result = normalize_messages(conv)
    assert len(result) == 2
    assert result[0] == {"role": "user", "content": "check service health"}
    assert result[1] == {"role": "assistant", "content": "Service is healthy."}


def test_normalize_tool_result_conversion():
    """Anthropic-style tool_result messages convert to ChatML tool role."""
    conv = [
        {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": "call_123",
                    "content": "active",
                }
            ],
        }
    ]
    result = normalize_messages(conv)
    assert len(result) == 1
    assert result[0]["role"] == "tool"
    assert result[0]["content"] == "active"
    assert result[0]["tool_call_id"] == "call_123"


def test_normalize_tool_calls_conversion():
    """Assistant tool_calls normalize to OpenAI function format."""
    conv = [
        {
            "role": "assistant",
            "content": "Let me check.",
            "tool_calls": [
                {
                    "id": "tc_1",
                    "name": "service_status",
                    "arguments": {"detail": True},
                }
            ],
        }
    ]
    result = normalize_messages(conv)
    assert len(result) == 1
    msg = result[0]
    assert msg["role"] == "assistant"
    assert msg["content"] == "Let me check."
    assert len(msg["tool_calls"]) == 1
    tc = msg["tool_calls"][0]
    assert tc["type"] == "function"
    assert tc["function"]["name"] == "service_status"
    assert json.loads(tc["function"]["arguments"]) == {"detail": True}


def test_normalize_skips_empty_content():
    """Messages with no content are dropped."""
    conv = [
        {"role": "user", "content": ""},
        {"role": "assistant", "content": None},
        {"role": "user", "content": "hello"},
    ]
    result = normalize_messages(conv)
    assert len(result) == 1
    assert result[0]["content"] == "hello"


# ── is_english / check_conversation_english ──────────────────────


def test_is_english_with_english_text():
    assert is_english("The service is running normally.") is True


def test_is_english_with_chinese_text():
    assert is_english("服务运行正常，所有检查已通过。") is False


def test_is_english_empty_string():
    assert is_english("") is True


def test_check_conversation_english_passes():
    msgs = [
        {"role": "user", "content": "check health"},
        {"role": "assistant", "content": "All systems operational."},
    ]
    assert check_conversation_english(msgs) is True


def test_check_conversation_english_fails():
    msgs = [
        {"role": "user", "content": "check health"},
        {"role": "assistant", "content": "服务运行正常，所有检查已通过。"},
    ]
    assert check_conversation_english(msgs) is False


# ── build_system_prompt ──────────────────────────────────────────


def test_build_system_prompt_structure():
    prompt = build_system_prompt("monitoring", "health_loop_escalation")
    assert "monitoring" in prompt
    assert "Room Agent" in prompt
    assert "Always respond in English" in prompt
    assert "resolved" in prompt
    assert "escalated" in prompt


# ── row_to_training_example ──────────────────────────────────────


def test_row_to_training_example_with_system():
    row = {
        "id": 42,
        "project": "my-service",
        "trigger": "schedule",
        "outcome": "no_action",
        "model": "qwen2.5:7b",
        "tokens_used": 150,
        "created_at": "2026-02-09T12:00:00",
        "conversation": [
            {"role": "user", "content": "run health check"},
            {"role": "assistant", "content": "All healthy."},
        ],
    }
    result = row_to_training_example(row, include_system=True)
    assert result is not None
    assert result["messages"][0]["role"] == "system"
    assert "my-service" in result["messages"][0]["content"]
    assert len(result["messages"]) == 3  # system + user + assistant
    assert result["metadata"]["source_id"] == 42
    assert result["metadata"]["project"] == "my-service"


def test_row_to_training_example_without_system():
    row = {
        "id": 1,
        "project": "redis",
        "trigger": "",
        "outcome": "resolved",
        "model": "",
        "tokens_used": 0,
        "created_at": None,
        "conversation": [
            {"role": "user", "content": "fix it"},
            {"role": "assistant", "content": "Fixed."},
        ],
    }
    result = row_to_training_example(row, include_system=False)
    assert result is not None
    assert len(result["messages"]) == 2
    assert result["messages"][0]["role"] == "user"


def test_row_to_training_example_empty_conversation():
    row = {
        "id": 1,
        "project": "test",
        "conversation": [],
    }
    assert row_to_training_example(row) is None


def test_row_to_training_example_single_message():
    row = {
        "id": 1,
        "project": "test",
        "trigger": "",
        "outcome": "",
        "model": "",
        "tokens_used": 0,
        "created_at": None,
        "conversation": [{"role": "user", "content": "hi"}],
    }
    # Only 1 message after normalize → too few
    assert row_to_training_example(row) is None


# ── mix_synthetic ──────────────────────────────────────────────


def _make_example(source_id: int, project: str = "monitoring") -> dict:
    return {
        "messages": [
            {"role": "user", "content": "check health"},
            {"role": "assistant", "content": "healthy"},
        ],
        "metadata": {"source_id": source_id, "project": project},
    }


def _make_synthetic(source_id: int) -> dict:
    ex = _make_example(source_id, "monitoring")
    ex["metadata"]["synthetic"] = True
    return ex


def test_mix_synthetic_30_percent():
    """With 10 real and 10 synthetic, at 0.30 ratio, ~4 synthetic are added."""
    real = [_make_example(i) for i in range(10)]
    synthetic = [_make_synthetic(100 + i) for i in range(10)]

    combined, n = mix_synthetic(real, synthetic, ratio=0.30)
    # 10 * 0.30 / 0.70 = 4.28 -> 4
    assert n == 4
    assert len(combined) == 14


def test_mix_synthetic_zero_ratio():
    """Ratio of 0 means no synthetic mixing."""
    real = [_make_example(i) for i in range(5)]
    synthetic = [_make_synthetic(i) for i in range(5)]

    combined, n = mix_synthetic(real, synthetic, ratio=0.0)
    assert n == 0
    assert len(combined) == 5


def test_mix_synthetic_empty_synthetic():
    """No synthetic data available -> returns real unchanged."""
    real = [_make_example(i) for i in range(5)]
    combined, n = mix_synthetic(real, [], ratio=0.30)
    assert n == 0
    assert len(combined) == 5


def test_mix_synthetic_empty_real():
    """Empty real dataset -> returns empty."""
    synthetic = [_make_synthetic(i) for i in range(5)]
    combined, n = mix_synthetic([], synthetic, ratio=0.30)
    assert n == 0
    assert len(combined) == 0


def test_mix_synthetic_caps_at_available():
    """When fewer synthetic than needed, uses all available."""
    real = [_make_example(i) for i in range(100)]
    synthetic = [_make_synthetic(i) for i in range(3)]

    combined, n = mix_synthetic(real, synthetic, ratio=0.30)
    # Would want ~42, but only 3 available
    assert n == 3
    assert len(combined) == 103


def test_mix_synthetic_default_ratio():
    """Default ratio is 0.30."""
    assert DEFAULT_SYNTHETIC_RATIO == 0.30


# ── export_training_data with include_synthetic ────────────────


def _make_db_row(
    id: int,
    project: str = "monitoring",
    outcome: str = "resolved",
    memory_type: str = "incident",
) -> dict:
    return {
        "id": id,
        "project": project,
        "memory_type": memory_type,
        "trigger": "health_loop",
        "context": "{}",
        "actions_taken": "[]",
        "outcome": outcome,
        "summary": "test",
        "tokens_used": 100,
        "model": "qwen2.5:7b",
        "conversation": json.dumps([
            {"role": "user", "content": "check health"},
            {"role": "assistant", "content": "healthy"},
        ]),
        "created_at": "2026-02-10T00:00:00",
    }


@pytest.mark.asyncio
async def test_export_without_synthetic():
    """Default export does not fetch synthetic data."""
    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=[
        _make_db_row(1, outcome="resolved"),
        _make_db_row(2, outcome="resolved"),
    ])

    examples, stats = await export_training_data(pool)
    assert stats.synthetic_mixed == 0
    assert stats.exported == 2
    # Should only have called EXPORT_SQL, not SYNTHETIC_SQL
    assert pool.fetch.await_count == 1


@pytest.mark.asyncio
async def test_export_with_synthetic():
    """include_synthetic=True fetches and mixes synthetic examples."""
    real_rows = [_make_db_row(i, outcome="resolved") for i in range(10)]
    synthetic_rows = [_make_db_row(100 + i, memory_type="synthetic") for i in range(5)]

    call_count = 0

    async def mock_fetch(sql, *args):
        nonlocal call_count
        call_count += 1
        if "memory_type = 'synthetic'" in sql:
            return synthetic_rows
        return real_rows

    pool = AsyncMock()
    pool.fetch = AsyncMock(side_effect=mock_fetch)

    examples, stats = await export_training_data(pool, include_synthetic=True)
    assert stats.synthetic_mixed > 0
    assert stats.exported == len(examples)
    assert call_count == 2  # EXPORT_SQL + SYNTHETIC_SQL
