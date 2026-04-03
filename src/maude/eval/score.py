# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Scoring functions for evaluating Room Agent conversation quality.

Each scorer analyzes a conversation dict and returns a float 0.0-1.0.
The composite_score function combines them with fixed weights.

Conversation format (from agent_memory.conversation column, JSON)::

    {
        "messages": [
            {"role": "user", "content": "Trigger: health_loop_escalation..."},
            {"role": "assistant", "content": "...", "tool_calls": [...]},
            {"role": "user", "content": [{"type": "tool_result", ...}]},
            {"role": "assistant", "content": "<summary>...</summary><outcome>resolved</outcome>"}
        ],
        "outcome": "resolved",
        "trigger": "health_loop_escalation",
        "actions": [{"name": "service_health", "arguments": {}}],
        "memory_type": "incident"
    }
"""

import re
from typing import Any

# Tool patterns expected for common trigger types
_DIAGNOSTIC_TOOLS = {
    "service_health", "service_status", "service_logs", "service_errors",
    "memory_recall_recent", "memory_recall_similar",
}

_ACTION_TOOLS = {
    "service_restart", "kill_switch_activate", "kill_switch_deactivate",
}

# Weights for the composite score (must sum to 1.0)
WEIGHTS: dict[str, float] = {
    "tool_selection": 0.30,
    "diagnosis": 0.25,
    "structured_output": 0.20,
    "noop_recognition": 0.15,
    "escalation_calibration": 0.10,
}


def _extract_tool_calls(conversation: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract all tool calls from conversation messages."""
    calls: list[dict[str, Any]] = []
    # From top-level actions list
    for action in conversation.get("actions") or []:
        if isinstance(action, dict) and action.get("name"):
            calls.append(action)
    # From message-level tool_calls
    for msg in conversation.get("messages") or []:
        if msg.get("role") == "assistant":
            for tc in msg.get("tool_calls") or []:
                if isinstance(tc, dict) and tc.get("name"):
                    calls.append(tc)
    return calls


def _extract_last_assistant_content(conversation: dict[str, Any]) -> str:
    """Get the content of the last assistant message."""
    messages = conversation.get("messages") or []
    for msg in reversed(messages):
        if msg.get("role") == "assistant" and isinstance(msg.get("content"), str):
            return msg["content"]
    return ""


def tool_selection_score(conversation: dict[str, Any]) -> float:
    """Score whether the agent called appropriate tools (weight: 30%).

    Returns 0.0 if no tools were called at all.
    Returns 1.0 if tools were called and at least one is a known
    diagnostic or action tool matching the conversation context.
    Returns 0.5 if tools were called but none match known patterns.
    """
    calls = _extract_tool_calls(conversation)
    if not calls:
        return 0.0

    tool_names = {c.get("name", "") for c in calls}
    known_tools = _DIAGNOSTIC_TOOLS | _ACTION_TOOLS

    matching = tool_names & known_tools
    if matching:
        return 1.0

    # Tools were called but none are from the known set — partial credit
    return 0.5


def diagnosis_score(conversation: dict[str, Any]) -> float:
    """Score whether the agent diagnosed before acting (weight: 25%).

    Checks that diagnostic tool calls appear before action tool calls
    in the conversation. If only diagnostic tools are used (no action
    needed), that scores 1.0. If action tools appear with no prior
    diagnostics, scores 0.0.
    """
    calls = _extract_tool_calls(conversation)
    if not calls:
        # No tools at all — depends on outcome
        outcome = conversation.get("outcome", "")
        return 1.0 if outcome == "no_action" else 0.0

    tool_names = [c.get("name", "") for c in calls]

    first_diagnostic: int | None = None
    first_action: int | None = None

    for i, name in enumerate(tool_names):
        if name in _DIAGNOSTIC_TOOLS and first_diagnostic is None:
            first_diagnostic = i
        if name in _ACTION_TOOLS and first_action is None:
            first_action = i

    # Only diagnostic tools — good pattern
    if first_diagnostic is not None and first_action is None:
        return 1.0

    # Action without any diagnostics — poor pattern
    if first_action is not None and first_diagnostic is None:
        return 0.2

    # Diagnostic before action — correct order
    if first_diagnostic is not None and first_action is not None:
        return 1.0 if first_diagnostic < first_action else 0.3

    # Tools called but none match known categories — neutral
    return 0.5


def structured_output_score(conversation: dict[str, Any]) -> float:
    """Score whether the response includes proper <summary> and <outcome> tags (weight: 20%).

    Returns 1.0 if both tags are present.
    Returns 0.5 if only one tag is present.
    Returns 0.0 if neither is present.
    """
    content = _extract_last_assistant_content(conversation)
    if not content:
        return 0.0

    has_summary = bool(re.search(r"<summary>.*?</summary>", content, re.DOTALL))
    has_outcome = bool(re.search(r"<outcome>.*?</outcome>", content, re.DOTALL))

    if has_summary and has_outcome:
        return 1.0
    if has_summary or has_outcome:
        return 0.5
    return 0.0


def noop_recognition_score(conversation: dict[str, Any]) -> float:
    """Score whether the agent correctly reports no_action when healthy (weight: 15%).

    When outcome is "no_action", checks that the agent didn't take
    unnecessary action tools. When outcome is NOT "no_action", checks
    that the agent did take action.
    """
    outcome = conversation.get("outcome", "")
    calls = _extract_tool_calls(conversation)
    tool_names = {c.get("name", "") for c in calls}
    action_tools_used = tool_names & _ACTION_TOOLS

    if outcome == "no_action":
        # Good: no action tools used when healthy
        return 0.0 if action_tools_used else 1.0

    # Non-no_action outcomes: agent should have done something
    # (diagnostic or action tools). If they correctly took action, score 1.0.
    if calls:
        return 1.0
    return 0.5


def escalation_calibration_score(conversation: dict[str, Any]) -> float:
    """Score escalation appropriateness (weight: 10%).

    Penalizes both unnecessary escalation (escalated when the issue
    was resolvable) and failure to escalate (failed without escalating).
    """
    outcome = conversation.get("outcome", "")

    if outcome == "escalated":
        # Escalation is appropriate — score based on whether diagnostic
        # tools were tried first
        calls = _extract_tool_calls(conversation)
        tool_names = {c.get("name", "") for c in calls}
        diagnosed_first = bool(tool_names & _DIAGNOSTIC_TOOLS)
        return 1.0 if diagnosed_first else 0.5

    if outcome == "failed":
        # Failed but didn't escalate — could be appropriate if it was
        # a known limitation, but generally penalize slightly
        return 0.5

    if outcome in ("resolved", "remediated", "no_action"):
        # Didn't escalate and resolved successfully — good
        return 1.0

    # Unknown outcome
    return 0.5


def composite_score(conversation: dict[str, Any]) -> float:
    """Weighted composite quality score for a conversation.

    Args:
        conversation: Dict with keys: messages (list), outcome (str),
                     trigger (str), actions (list of tool calls),
                     memory_type (str)
    Returns:
        Score 0.0-1.0
    """
    scores = {
        "tool_selection": tool_selection_score(conversation),
        "diagnosis": diagnosis_score(conversation),
        "structured_output": structured_output_score(conversation),
        "noop_recognition": noop_recognition_score(conversation),
        "escalation_calibration": escalation_calibration_score(conversation),
    }

    total = sum(scores[k] * WEIGHTS[k] for k in WEIGHTS)
    return round(total, 4)
