# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Training data export from agent_memory conversations.

Provides pure functions for converting stored conversations into ChatML
training examples, plus async helpers for counting and bulk-exporting
from PostgreSQL.

The CLI at ``scripts/export-training-data.py`` wraps these functions.
The ``TrainingLoop`` calls ``count_new_examples`` and ``export_training_data``
directly.
"""

import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import asyncpg

EXPORT_SQL = """
    SELECT id, project, memory_type, trigger, context,
           actions_taken, outcome, summary, tokens_used, model,
           conversation, created_at
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
    ORDER BY created_at DESC
"""

COUNT_NEW_SQL = """
    SELECT count(*) FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
      AND created_at > $1
"""

STATS_SQL = """
    SELECT
        project,
        outcome,
        count(*) as count,
        avg(jsonb_array_length(conversation)) as avg_msgs,
        avg(tokens_used) as avg_tokens,
        avg(length(conversation::text)) as avg_bytes
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
    GROUP BY project, outcome
    ORDER BY project, count DESC
"""

# CJK Unicode ranges: Chinese, Japanese Hiragana/Katakana, Korean
_NON_ENGLISH_RE = re.compile(
    r"[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\uac00-\ud7af"
    r"\u0400-\u04ff\u0600-\u06ff]"  # Cyrillic, Arabic
)


SYNTHETIC_SQL = """
    SELECT id, project, memory_type, trigger, context,
           actions_taken, outcome, summary, tokens_used, model,
           conversation, created_at
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
      AND memory_type = 'synthetic'
    ORDER BY created_at DESC
"""

CONCIERGE_SQL = """
    SELECT id, project, memory_type, trigger, context,
           actions_taken, outcome, summary, tokens_used, model,
           conversation, created_at
    FROM agent_memory
    WHERE conversation IS NOT NULL
      AND jsonb_array_length(conversation) > 1
      AND memory_type = 'concierge'
    ORDER BY created_at DESC
"""

DEFAULT_SYNTHETIC_RATIO = 0.30


@dataclass
class ExportStats:
    """Statistics from an export run."""

    total_fetched: int = 0
    exported: int = 0
    skipped_quality: int = 0
    skipped_english: int = 0
    skipped_empty: int = 0
    synthetic_mixed: int = 0
    projects: set[str] = field(default_factory=set)


def normalize_messages(conversation: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Convert stored conversation to ChatML-compatible format.

    Transforms:
    - Anthropic-style tool results -> {"role": "tool", "content": ..., "tool_call_id": ...}
    - Strips null/empty content fields
    - Normalizes tool_calls to OpenAI format
    """
    normalized: list[dict[str, Any]] = []

    for msg in conversation:
        role = msg.get("role", "")

        # Tool result messages (Anthropic format -> ChatML tool role)
        if role == "user" and isinstance(msg.get("content"), list):
            for item in msg["content"]:
                if isinstance(item, dict) and item.get("type") == "tool_result":
                    normalized.append({
                        "role": "tool",
                        "content": item.get("content", ""),
                        "tool_call_id": item.get("tool_use_id", ""),
                    })
            continue

        # Assistant messages with tool calls
        if role == "assistant" and msg.get("tool_calls"):
            entry: dict[str, Any] = {"role": "assistant"}
            if msg.get("content"):
                entry["content"] = msg["content"]
            entry["tool_calls"] = [
                {
                    "id": tc.get("id", ""),
                    "type": "function",
                    "function": {
                        "name": tc.get("name", ""),
                        "arguments": json.dumps(tc.get("arguments", {})),
                    },
                }
                for tc in msg["tool_calls"]
            ]
            normalized.append(entry)
            continue

        # Regular user/assistant messages
        if role in ("user", "assistant") and msg.get("content"):
            normalized.append({"role": role, "content": msg["content"]})

    return normalized


def is_english(text: str, threshold: float = 0.02) -> bool:
    """Check if text is predominantly English.

    Returns False if non-English characters exceed the threshold ratio.
    Threshold of 0.02 allows for occasional Unicode in tool output
    while catching full non-English responses.
    """
    if not text:
        return True
    non_english_chars = len(_NON_ENGLISH_RE.findall(text))
    return (non_english_chars / len(text)) < threshold


def check_conversation_english(messages: list[dict[str, Any]]) -> bool:
    """Verify all assistant messages in a conversation are English."""
    for msg in messages:
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content", "")
        if isinstance(content, str) and not is_english(content):
            return False
    return True


def build_system_prompt(project: str, trigger: str) -> str:
    """Build a minimal system prompt for the training example."""
    return (
        f"You are a Room Agent for {project}. "
        "You diagnose and resolve infrastructure issues using the tools available to you. "
        "Use diagnostic tools first, then take corrective action if needed. "
        "Always respond in English. "
        "End your response with <summary> and <outcome> tags.\n\n"
        "Valid outcomes: resolved, remediated, failed, escalated, no_action\n"
        "- resolved = diagnosed and fixed\n"
        "- remediated = diagnosed, fixed, AND verified\n"
        "- no_action = everything healthy\n"
        "- failed = could not fix\n"
        "- escalated = needs more capable model"
    )


def row_to_training_example(
    row: asyncpg.Record | dict[str, Any],
    include_system: bool = True,
) -> dict[str, Any] | None:
    """Convert a database row to a ChatML training example."""
    conversation = row["conversation"]
    if isinstance(conversation, str):
        conversation = json.loads(conversation)

    if not conversation:
        return None

    messages = normalize_messages(conversation)
    if len(messages) < 2:
        return None

    if include_system:
        system = build_system_prompt(row["project"], row.get("trigger") or "")
        messages.insert(0, {"role": "system", "content": system})

    return {
        "messages": messages,
        "metadata": {
            "source_id": row["id"],
            "project": row["project"],
            "outcome": row.get("outcome") or "",
            "model": row.get("model") or "",
            "tokens_used": row.get("tokens_used") or 0,
            "trigger": row.get("trigger") or "",
            "created_at": (
                row["created_at"].isoformat()
                if hasattr(row.get("created_at"), "isoformat")
                else str(row.get("created_at", ""))
            ),
        },
    }


# ── Async helpers (used by TrainingLoop) ────────────────────────


async def count_new_examples(
    pool: asyncpg.Pool,
    since: datetime,
) -> int:
    """Count trainable conversations created after ``since``."""
    row = await pool.fetchval(COUNT_NEW_SQL, since)
    return int(row or 0)


async def export_training_data(
    pool: asyncpg.Pool,
    min_tools: int = 0,
    outcomes: list[str] | None = None,
    include_system: bool = True,
    include_synthetic: bool = False,
    synthetic_ratio: float = DEFAULT_SYNTHETIC_RATIO,
) -> tuple[list[dict[str, Any]], ExportStats]:
    """Export all trainable conversations from agent_memory.

    Args:
        pool: asyncpg connection pool pointed at the ``agent`` database.
        min_tools: Minimum tool calls required per conversation.
        outcomes: Allowed outcomes. Defaults to resolved, remediated, no_action.
        include_system: Whether to prepend system prompts.
        include_synthetic: Whether to mix in synthetic training examples
            (memory_type='synthetic'). Mixed at ``synthetic_ratio`` of the
            total dataset.
        synthetic_ratio: Target fraction of synthetic examples in the final
            dataset. Defaults to 0.30 (30%).

    Returns:
        Tuple of (training examples list, export statistics).
    """
    if outcomes is None:
        outcomes = ["resolved", "remediated", "no_action"]

    rows = await pool.fetch(EXPORT_SQL)
    stats = ExportStats(total_fetched=len(rows))
    examples: list[dict[str, Any]] = []

    for row in rows:
        # Outcome filter
        outcome = row["outcome"] or ""
        if outcomes and outcome not in outcomes:
            stats.skipped_quality += 1
            continue

        # Min tool calls filter
        if min_tools > 0:
            actions = row["actions_taken"]
            if isinstance(actions, str):
                actions = json.loads(actions)
            if not actions or len(actions) < min_tools:
                stats.skipped_quality += 1
                continue

        # Language filter
        conversation = row["conversation"]
        if isinstance(conversation, str):
            conversation = json.loads(conversation)
        if not check_conversation_english(conversation or []):
            stats.skipped_english += 1
            continue

        # Convert
        example = row_to_training_example(row, include_system=include_system)
        if example is None:
            stats.skipped_empty += 1
            continue

        examples.append(example)
        stats.projects.add(row["project"])

    # Mix synthetic examples if requested
    if include_synthetic and examples:
        synthetic_examples = await _fetch_synthetic(pool, include_system)
        examples, synthetic_count = mix_synthetic(
            examples, synthetic_examples, synthetic_ratio,
        )
        stats.synthetic_mixed = synthetic_count

    stats.exported = len(examples)
    return examples, stats


async def _fetch_synthetic(
    pool: asyncpg.Pool,
    include_system: bool = True,
) -> list[dict[str, Any]]:
    """Fetch synthetic training examples from agent_memory."""
    rows = await pool.fetch(SYNTHETIC_SQL)
    examples: list[dict[str, Any]] = []
    for row in rows:
        example = row_to_training_example(row, include_system=include_system)
        if example is not None:
            example["metadata"]["synthetic"] = True
            examples.append(example)
    return examples


def mix_synthetic(
    real: list[dict[str, Any]],
    synthetic: list[dict[str, Any]],
    ratio: float = DEFAULT_SYNTHETIC_RATIO,
) -> tuple[list[dict[str, Any]], int]:
    """Mix synthetic examples into a real dataset at the target ratio.

    The target ratio determines how many synthetic examples to include
    relative to the total. E.g., ratio=0.30 means the final dataset will
    be ~30% synthetic, ~70% real.

    Args:
        real: Real training examples.
        synthetic: Synthetic training examples to mix in.
        ratio: Target synthetic fraction (0.0 to 1.0).

    Returns:
        Tuple of (combined examples, count of synthetic examples included).
    """
    if not synthetic or ratio <= 0.0:
        return real, 0

    # Calculate how many synthetic examples to include
    # target_total = real_count / (1 - ratio)
    # synthetic_count = target_total - real_count = real_count * ratio / (1 - ratio)
    max_synthetic = int(len(real) * ratio / max(1.0 - ratio, 0.01))
    n_synthetic = min(max_synthetic, len(synthetic))

    if n_synthetic == 0:
        return real, 0

    combined = real + synthetic[:n_synthetic]
    return combined, n_synthetic


# ── Interaction log export ────────────────────────────────────────

INTERACTION_SQL = """
    SELECT id, project, surface, caller, request, response,
           duration_ms, success, created_at
    FROM interaction_log
    WHERE success = true
      AND response IS NOT NULL
    ORDER BY created_at DESC
"""

INTERACTION_COUNT_SQL = """
    SELECT count(*) FROM interaction_log
    WHERE success = true
      AND response IS NOT NULL
      AND created_at > $1
"""


def interaction_to_training_example(
    row: "asyncpg.Record | dict[str, Any]",
) -> dict[str, Any] | None:
    """Convert an interaction_log row to a ChatML training example."""
    request = row["request"]
    response = row["response"]
    if isinstance(request, str):
        request = json.loads(request)
    if isinstance(response, str):
        response = json.loads(response)

    tool_name = request.get("tool", "")
    params = request.get("params", {})
    response_text = response.get("text", "")

    if not tool_name or not response_text:
        return None

    # Build a user message from the tool call
    user_content = f"Use the {tool_name} tool"
    if params:
        param_desc = ", ".join(f"{k}={v!r}" for k, v in params.items())
        user_content += f" with {param_desc}"

    system = (
        f"You are a Room Agent for {row['project']}. "
        "You use MCP tools to answer operational questions and manage infrastructure. "
        "Always respond in English."
    )

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user_content},
        {
            "role": "assistant",
            "content": response_text[:8000],
            "tool_calls": [{
                "id": f"interaction-{row['id']}",
                "type": "function",
                "function": {
                    "name": tool_name,
                    "arguments": json.dumps(params, default=str),
                },
            }],
        },
    ]

    return {
        "messages": messages,
        "metadata": {
            "source_id": row["id"],
            "source": "interaction_log",
            "project": row["project"],
            "surface": row["surface"],
            "created_at": (
                row["created_at"].isoformat()
                if hasattr(row.get("created_at"), "isoformat")
                else str(row.get("created_at", ""))
            ),
        },
    }


async def count_new_interactions(
    pool: "asyncpg.Pool",
    since: "datetime",
) -> int:
    """Count interaction_log entries created after ``since``."""
    try:
        row = await pool.fetchval(INTERACTION_COUNT_SQL, since)
        return int(row or 0)
    except Exception:
        return 0


async def export_interaction_data(
    pool: "asyncpg.Pool",
    limit: int = 5000,
) -> tuple[list[dict[str, Any]], ExportStats]:
    """Export interaction_log entries as training examples.

    Returns:
        Tuple of (training examples list, export statistics).
    """
    stats = ExportStats()
    examples: list[dict[str, Any]] = []

    try:
        rows = await pool.fetch(f"{INTERACTION_SQL} LIMIT {limit}")
    except Exception:
        return examples, stats

    stats.total_fetched = len(rows)

    for row in rows:
        example = interaction_to_training_example(row)
        if example is None:
            stats.skipped_empty += 1
            continue
        examples.append(example)
        stats.projects.add(row["project"])

    stats.exported = len(examples)
    return examples, stats


# ── Concierge export ──────────────────────────────────────────────


def build_concierge_system_prompt(department: str | None = None) -> str:
    """Build a system prompt for concierge training examples."""
    base = (
        "You are the Maude Concierge for your organization. "
        "You assist operators and managers with questions about "
        "infrastructure, services, departments, and procedures. "
        "Route domain-specific questions to the appropriate department agent. "
        "Always respond in English."
    )
    if department:
        base += f"\n\nYou are answering on behalf of the {department} department."
    return base


def concierge_row_to_example(
    row: asyncpg.Record | dict[str, Any],
) -> dict[str, Any] | None:
    """Convert a concierge memory row to a ChatML training example."""
    conversation = row["conversation"]
    if isinstance(conversation, str):
        conversation = json.loads(conversation)
    if not conversation:
        return None

    messages = normalize_messages(conversation)
    if len(messages) < 2:
        return None

    context = row.get("context") or {}
    if isinstance(context, str):
        context = json.loads(context)
    department = context.get("department")

    system = build_concierge_system_prompt(department)
    messages.insert(0, {"role": "system", "content": system})

    return {
        "messages": messages,
        "metadata": {
            "source_id": row["id"],
            "project": "maude",
            "department": department or "",
            "outcome": row.get("outcome") or "",
            "model": row.get("model") or "",
            "tokens_used": row.get("tokens_used") or 0,
            "trigger": "web_chat",
            "created_at": (
                row["created_at"].isoformat()
                if hasattr(row.get("created_at"), "isoformat")
                else str(row.get("created_at", ""))
            ),
        },
    }


async def export_concierge_data(
    pool: asyncpg.Pool,
    output_dir: str | None = None,
    filter_config: Any = None,
) -> tuple[dict[str, list[dict[str, Any]]], ExportStats]:
    """Export concierge conversations grouped by department.

    Args:
        pool: asyncpg connection pool.
        output_dir: Optional directory to write per-department JSONL files.
        filter_config: Optional TrainingFilterConfig for data boundary filters.

    Returns:
        Tuple of (department->examples dict, export statistics).
    """
    from maude.healing.training.filter import TrainingFilterConfig, filter_conversation

    if filter_config is None:
        filter_config = TrainingFilterConfig()

    rows = await pool.fetch(CONCIERGE_SQL)
    stats = ExportStats(total_fetched=len(rows))
    by_department: dict[str, list[dict[str, Any]]] = {}

    for row in rows:
        conversation = row["conversation"]
        if isinstance(conversation, str):
            conversation = json.loads(conversation)

        # Apply training filters (ITAR, PII, quality, language).
        cleaned = filter_conversation(conversation or [], filter_config)
        if cleaned is None:
            stats.skipped_quality += 1
            continue

        # Build example from filtered conversation.
        filtered_row = dict(row)
        filtered_row["conversation"] = cleaned
        example = concierge_row_to_example(filtered_row)
        if example is None:
            stats.skipped_empty += 1
            continue

        dept = example["metadata"].get("department") or "general"
        by_department.setdefault(dept, []).append(example)
        stats.projects.add("maude")

    stats.exported = sum(len(v) for v in by_department.values())

    # Write JSONL files if output_dir specified.
    if output_dir:
        from pathlib import Path

        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)

        all_examples: list[dict[str, Any]] = []
        for dept, examples in by_department.items():
            dept_file = out / f"{dept}-concierge.jsonl"
            with dept_file.open("w") as f:
                for ex in examples:
                    f.write(json.dumps(ex, default=str, ensure_ascii=False) + "\n")
            all_examples.extend(examples)

        if all_examples:
            merged = out / "concierge-all.jsonl"
            with merged.open("w") as f:
                for ex in all_examples:
                    f.write(json.dumps(ex, default=str, ensure_ascii=False) + "\n")

    return by_department, stats
