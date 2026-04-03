# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Benchmark runner for evaluating Room Agent model quality.

Replays historical conversations against candidate models and scores
the results using the scoring module.

Usage::

    result = await run_benchmark("qwen2.5:7b", test_set)
    print(f"Avg score: {result.avg_score:.3f}, Pass rate: {result.pass_rate:.1%}")
"""

import logging
import time
from dataclasses import dataclass
from typing import Any

import asyncpg

from maude.eval.score import (
    composite_score,
    diagnosis_score,
    escalation_calibration_score,
    noop_recognition_score,
    structured_output_score,
    tool_selection_score,
)
from maude.healing.training.export import build_system_prompt
from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)

PASS_THRESHOLD = 0.80

# SQL to extract test conversations with stratified sampling
_TEST_SET_SQL = """
    SELECT id, project, memory_type, trigger, context,
           actions_taken, outcome, summary, tokens_used, model,
           conversation, created_at
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
      AND id IN (
          SELECT memory_id FROM training_splits WHERE split = 'test'
      )
    ORDER BY created_at DESC
    LIMIT $1
"""

_STRATIFIED_SAMPLE_SQL = """
    SELECT id, project, outcome, conversation
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
      AND id NOT IN (SELECT memory_id FROM training_splits)
    ORDER BY created_at DESC
"""

_INSERT_SPLIT_SQL = """
    INSERT INTO training_splits (memory_id, split)
    VALUES ($1, $2)
    ON CONFLICT (memory_id) DO NOTHING
"""

_SPLIT_COUNTS_SQL = """
    SELECT split, count(*) as count
    FROM training_splits
    GROUP BY split
"""


@dataclass
class BenchmarkResult:
    """Aggregated results from a benchmark run."""

    model: str
    test_count: int
    avg_score: float
    tool_selection_avg: float
    diagnosis_avg: float
    structured_output_avg: float
    noop_recognition_avg: float
    escalation_calibration_avg: float
    pass_rate: float  # % scoring above PASS_THRESHOLD
    duration_seconds: float


def _extract_trigger_context(conversation: list[dict[str, Any]]) -> str:
    """Extract the trigger and context from the first user message."""
    for msg in conversation:
        if msg.get("role") == "user" and isinstance(msg.get("content"), str):
            return msg["content"]
    return ""


async def run_benchmark(
    model: str,
    test_set: list[dict[str, Any]],
    vllm_hosts: list[str] | None = None,
) -> BenchmarkResult:
    """Replay test conversations against a candidate model and score results.

    Args:
        model: vLLM model name to evaluate.
        test_set: List of conversation dicts from create_test_set.
        vllm_hosts: Optional explicit vLLM host list.

    Returns:
        BenchmarkResult with aggregated scores.
    """
    client = VLLMClient(hosts=vllm_hosts)
    t0 = time.monotonic()

    scores: list[float] = []
    tool_scores: list[float] = []
    diag_scores: list[float] = []
    struct_scores: list[float] = []
    noop_scores: list[float] = []
    esc_scores: list[float] = []

    try:
        for entry in test_set:
            try:
                scored = await _replay_and_score(client, model, entry)
                scores.append(composite_score(scored))
                tool_scores.append(tool_selection_score(scored))
                diag_scores.append(diagnosis_score(scored))
                struct_scores.append(structured_output_score(scored))
                noop_scores.append(noop_recognition_score(scored))
                esc_scores.append(escalation_calibration_score(scored))
            except Exception:
                logger.warning(
                    "Benchmark: failed to replay entry %s", entry.get("id"), exc_info=True,
                )
    finally:
        await client.close()

    duration = time.monotonic() - t0
    n = len(scores) or 1  # avoid division by zero

    return BenchmarkResult(
        model=model,
        test_count=len(scores),
        avg_score=round(sum(scores) / n, 4),
        tool_selection_avg=round(sum(tool_scores) / n, 4),
        diagnosis_avg=round(sum(diag_scores) / n, 4),
        structured_output_avg=round(sum(struct_scores) / n, 4),
        noop_recognition_avg=round(sum(noop_scores) / n, 4),
        escalation_calibration_avg=round(sum(esc_scores) / n, 4),
        pass_rate=round(sum(1 for s in scores if s >= PASS_THRESHOLD) / n, 4),
        duration_seconds=round(duration, 1),
    )


async def _replay_and_score(
    client: VLLMClient,
    model: str,
    entry: dict[str, Any],
) -> dict[str, Any]:
    """Replay a single conversation and build a scored conversation dict.

    Sends the trigger to the candidate model and constructs a conversation
    dict from the response for scoring.
    """
    original_conversation = entry.get("conversation") or []
    trigger_text = _extract_trigger_context(original_conversation)
    project = entry.get("project", "unknown")
    trigger = entry.get("trigger", "")
    original_outcome = entry.get("outcome", "")

    system_prompt = build_system_prompt(project, trigger)

    response = await client.generate(
        model=model,
        system=system_prompt,
        prompt=trigger_text,
        stream=False,
    )

    response_text = response.response if hasattr(response, "response") else str(response)

    # Build a conversation dict for scoring
    return {
        "messages": [
            {"role": "user", "content": trigger_text},
            {"role": "assistant", "content": response_text},
        ],
        "outcome": original_outcome,
        "trigger": trigger,
        "actions": [],
        "memory_type": entry.get("memory_type", ""),
    }


async def create_test_set(
    pool: asyncpg.Pool,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """Extract test conversations from agent_memory using training_splits.

    Args:
        pool: asyncpg connection pool for the agent database.
        limit: Maximum number of test conversations.

    Returns:
        List of conversation dicts suitable for run_benchmark.
    """
    rows = await pool.fetch(_TEST_SET_SQL, limit)

    test_set: list[dict[str, Any]] = []
    for row in rows:
        conversation = row["conversation"]
        if isinstance(conversation, str):
            import json
            conversation = json.loads(conversation)

        test_set.append({
            "id": row["id"],
            "project": row["project"],
            "memory_type": row["memory_type"],
            "trigger": row["trigger"] or "",
            "outcome": row["outcome"] or "",
            "conversation": conversation,
            "model": row["model"] or "",
        })

    return test_set


async def assign_splits(
    pool: asyncpg.Pool,
    test_ratio: float = 0.2,
) -> dict[str, int]:
    """Assign memories to train/test/validation splits.

    Uses stratified sampling by outcome and project to ensure
    balanced representation across splits.

    Args:
        pool: asyncpg connection pool for the agent database.
        test_ratio: Fraction of data for test split (validation gets same ratio).

    Returns:
        Dict with counts per split: {"train": N, "test": N, "validation": N}.
    """
    rows = await pool.fetch(_STRATIFIED_SAMPLE_SQL)
    if not rows:
        return {"train": 0, "test": 0, "validation": 0}

    # Group by (project, outcome) for stratification
    groups: dict[tuple[str, str], list[int]] = {}
    for row in rows:
        key = (row["project"], row["outcome"] or "unknown")
        groups.setdefault(key, []).append(row["id"])

    counts = {"train": 0, "test": 0, "validation": 0}
    validation_ratio = test_ratio

    for _key, ids in groups.items():
        n = len(ids)
        n_test = max(1, int(n * test_ratio)) if n >= 3 else 0
        n_val = max(1, int(n * validation_ratio)) if n >= 3 else 0
        n_train = n - n_test - n_val

        # Ensure we don't over-allocate
        if n_train < 0:
            n_train = 0
            n_test = n // 2
            n_val = n - n_test

        splits: list[tuple[int, str]] = []
        for i, memory_id in enumerate(ids):
            if i < n_test:
                split = "test"
            elif i < n_test + n_val:
                split = "validation"
            else:
                split = "train"
            splits.append((memory_id, split))
            counts[split] += 1

        # Batch insert
        await pool.executemany(_INSERT_SPLIT_SQL, splits)

    logger.info(
        "Assigned splits: train=%d, test=%d, validation=%d",
        counts["train"], counts["test"], counts["validation"],
    )
    return counts
