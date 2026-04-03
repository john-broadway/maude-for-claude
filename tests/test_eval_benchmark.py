# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.eval.benchmark — benchmark runner, test set creation, splits."""

from unittest.mock import AsyncMock, patch

import pytest

from maude.eval.benchmark import (
    BenchmarkResult,
    assign_splits,
    create_test_set,
    run_benchmark,
)

# ── Fixtures ────────────────────────────────────────────────────


def _make_test_entry(
    id: int = 1,
    project: str = "monitoring",
    outcome: str = "resolved",
    trigger: str = "health_loop_escalation",
) -> dict:
    return {
        "id": id,
        "project": project,
        "memory_type": "incident",
        "trigger": trigger,
        "outcome": outcome,
        "conversation": [
            {"role": "user", "content": f"Trigger: {trigger} for {project}"},
            {
                "role": "assistant",
                "content": ("<summary>Checked and resolved.</summary><outcome>resolved</outcome>"),
                "tool_calls": [{"name": "service_health", "arguments": {}}],
            },
        ],
        "model": "qwen2.5:7b",
    }


class FakeVLLMResponse:
    def __init__(self, text: str = "") -> None:
        self.response = text


# ── run_benchmark ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_run_benchmark_basic():
    """Benchmark scores a test set using a mocked VLLMClient."""
    test_set = [_make_test_entry(id=i) for i in range(3)]

    response_text = "<summary>Service was down, restarted.</summary><outcome>resolved</outcome>"

    with patch("maude.eval.benchmark.VLLMClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.generate = AsyncMock(return_value=FakeVLLMResponse(response_text))
        mock_client.close = AsyncMock()
        MockClient.return_value = mock_client

        result = await run_benchmark("test-model", test_set)

    assert isinstance(result, BenchmarkResult)
    assert result.model == "test-model"
    assert result.test_count == 3
    assert 0.0 <= result.avg_score <= 1.0
    assert 0.0 <= result.pass_rate <= 1.0
    assert result.duration_seconds >= 0


@pytest.mark.asyncio
async def test_run_benchmark_empty_test_set():
    """Empty test set produces zeroed results without errors."""
    with patch("maude.eval.benchmark.VLLMClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.close = AsyncMock()
        MockClient.return_value = mock_client

        result = await run_benchmark("test-model", [])

    assert result.test_count == 0
    assert result.avg_score == 0.0


@pytest.mark.asyncio
async def test_run_benchmark_with_explicit_hosts():
    """Explicit vllm_hosts are passed through to VLLMClient."""
    test_set = [_make_test_entry()]

    with patch("maude.eval.benchmark.VLLMClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.generate = AsyncMock(return_value=FakeVLLMResponse("ok"))
        mock_client.close = AsyncMock()
        MockClient.return_value = mock_client

        await run_benchmark("m", test_set, vllm_hosts=["host1", "host2"])
        MockClient.assert_called_once_with(hosts=["host1", "host2"])


@pytest.mark.asyncio
async def test_run_benchmark_handles_replay_failure():
    """Individual replay failures are skipped, not fatal."""
    test_set = [_make_test_entry(id=1), _make_test_entry(id=2)]

    call_count = 0

    async def flaky_generate(**kwargs):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise ConnectionError("vllm down")
        return FakeVLLMResponse("<summary>ok</summary><outcome>resolved</outcome>")

    with patch("maude.eval.benchmark.VLLMClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.generate = AsyncMock(side_effect=flaky_generate)
        mock_client.close = AsyncMock()
        MockClient.return_value = mock_client

        result = await run_benchmark("m", test_set)

    # Only one succeeded
    assert result.test_count == 1


# ── BenchmarkResult ─────────────────────────────────────────────


def test_benchmark_result_fields():
    r = BenchmarkResult(
        model="test",
        test_count=10,
        avg_score=0.85,
        tool_selection_avg=0.9,
        diagnosis_avg=0.8,
        structured_output_avg=0.7,
        noop_recognition_avg=0.95,
        escalation_calibration_avg=1.0,
        pass_rate=0.8,
        duration_seconds=12.5,
    )
    assert r.model == "test"
    assert r.test_count == 10
    assert r.pass_rate == 0.8


# ── create_test_set ─────────────────────────────────────────────


def _make_db_row(
    id: int = 1,
    project: str = "monitoring",
    outcome: str = "resolved",
) -> dict:
    """Simulate an asyncpg.Record as a dict."""
    import json

    return {
        "id": id,
        "project": project,
        "memory_type": "incident",
        "trigger": "health_loop",
        "context": "{}",
        "actions_taken": "[]",
        "outcome": outcome,
        "summary": "test",
        "tokens_used": 100,
        "model": "qwen2.5:7b",
        "conversation": json.dumps(
            [
                {"role": "user", "content": "check health"},
                {"role": "assistant", "content": "healthy"},
            ]
        ),
        "created_at": "2026-02-10T00:00:00",
    }


@pytest.mark.asyncio
async def test_create_test_set_extracts_rows():
    pool = AsyncMock()
    pool.fetch = AsyncMock(
        return_value=[
            _make_db_row(id=1, project="monitoring", outcome="resolved"),
            _make_db_row(id=2, project="my-service", outcome="no_action"),
        ]
    )

    test_set = await create_test_set(pool, limit=50)
    assert len(test_set) == 2
    assert test_set[0]["id"] == 1
    assert test_set[0]["project"] == "monitoring"
    assert test_set[1]["outcome"] == "no_action"
    assert isinstance(test_set[0]["conversation"], list)


@pytest.mark.asyncio
async def test_create_test_set_empty():
    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=[])

    test_set = await create_test_set(pool, limit=100)
    assert test_set == []


# ── assign_splits ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_assign_splits_basic():
    """Assigns memories to train/test/validation splits."""
    # 10 rows: 5 monitoring/resolved, 5 my-service/no_action
    rows = []
    for i in range(5):
        rows.append(
            {
                "id": i + 1,
                "project": "monitoring",
                "outcome": "resolved",
                "conversation": "[]",
            }
        )
    for i in range(5):
        rows.append(
            {
                "id": i + 6,
                "project": "my-service",
                "outcome": "no_action",
                "conversation": "[]",
            }
        )

    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=rows)
    pool.executemany = AsyncMock()

    counts = await assign_splits(pool, test_ratio=0.2)
    assert "train" in counts
    assert "test" in counts
    assert "validation" in counts
    total = counts["train"] + counts["test"] + counts["validation"]
    assert total == 10


@pytest.mark.asyncio
async def test_assign_splits_empty():
    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=[])
    pool.executemany = AsyncMock()

    counts = await assign_splits(pool)
    assert counts == {"train": 0, "test": 0, "validation": 0}


@pytest.mark.asyncio
async def test_assign_splits_ratio():
    """Test split with 0.2 ratio produces roughly 20% test."""
    rows = [
        {"id": i, "project": "monitoring", "outcome": "resolved", "conversation": "[]"}
        for i in range(20)
    ]

    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=rows)
    pool.executemany = AsyncMock()

    counts = await assign_splits(pool, test_ratio=0.2)
    # With 20 items in one group, test should be ~4
    assert counts["test"] >= 1
    assert counts["validation"] >= 1
    assert counts["train"] >= counts["test"]
