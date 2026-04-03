# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.eval.score — individual scorers and composite."""

from maude.eval.score import (
    WEIGHTS,
    composite_score,
    diagnosis_score,
    escalation_calibration_score,
    noop_recognition_score,
    structured_output_score,
    tool_selection_score,
)

# ── Sample conversations ────────────────────────────────────────


def _perfect_conversation() -> dict:
    """A conversation that should score 1.0 across all dimensions."""
    return {
        "messages": [
            {"role": "user", "content": "Trigger: health_loop_escalation for monitoring"},
            {
                "role": "assistant",
                "content": "Let me check the service health.",
                "tool_calls": [{"name": "service_health", "arguments": {}}],
            },
            {
                "role": "user",
                "content": [{"type": "tool_result", "tool_use_id": "c1", "content": "unhealthy"}],
            },
            {
                "role": "assistant",
                "content": "Restarting the service.",
                "tool_calls": [{"name": "service_restart", "arguments": {}}],
            },
            {
                "role": "user",
                "content": [{"type": "tool_result", "tool_use_id": "c2", "content": "ok"}],
            },
            {
                "role": "assistant",
                "content": (
                    "<summary>The service was unhealthy. Diagnosed via service_health, "
                    "restarted successfully.</summary>"
                    "<outcome>resolved</outcome>"
                ),
            },
        ],
        "outcome": "resolved",
        "trigger": "health_loop_escalation",
        "actions": [
            {"name": "service_health", "arguments": {}},
            {"name": "service_restart", "arguments": {}},
        ],
        "memory_type": "incident",
    }


def _no_tools_conversation() -> dict:
    """A conversation with no tool calls at all."""
    return {
        "messages": [
            {"role": "user", "content": "check health"},
            {"role": "assistant", "content": "Everything looks fine."},
        ],
        "outcome": "no_action",
        "trigger": "schedule",
        "actions": [],
        "memory_type": "health_check",
    }


def _healthy_noop_conversation() -> dict:
    """Agent correctly reports no_action for a healthy system."""
    return {
        "messages": [
            {"role": "user", "content": "Trigger: schedule health check"},
            {
                "role": "assistant",
                "content": "Checking service health.",
                "tool_calls": [{"name": "service_health", "arguments": {}}],
            },
            {
                "role": "user",
                "content": [{"type": "tool_result", "tool_use_id": "c1", "content": "healthy"}],
            },
            {
                "role": "assistant",
                "content": (
                    "<summary>All services healthy, no action needed.</summary>"
                    "<outcome>no_action</outcome>"
                ),
            },
        ],
        "outcome": "no_action",
        "trigger": "schedule",
        "actions": [{"name": "service_health", "arguments": {}}],
        "memory_type": "health_check",
    }


# ── WEIGHTS ─────────────────────────────────────────────────────


def test_weights_sum_to_one():
    total = sum(WEIGHTS.values())
    assert abs(total - 1.0) < 1e-9


# ── tool_selection_score ────────────────────────────────────────


def test_tool_selection_no_tools():
    conv = _no_tools_conversation()
    assert tool_selection_score(conv) == 0.0


def test_tool_selection_known_tools():
    conv = _perfect_conversation()
    assert tool_selection_score(conv) == 1.0


def test_tool_selection_unknown_tools():
    conv = {
        "messages": [
            {
                "role": "assistant",
                "content": "ok",
                "tool_calls": [{"name": "custom_tool", "arguments": {}}],
            },
        ],
        "actions": [{"name": "custom_tool", "arguments": {}}],
        "outcome": "resolved",
        "trigger": "",
    }
    assert tool_selection_score(conv) == 0.5


# ── diagnosis_score ─────────────────────────────────────────────


def test_diagnosis_correct_order():
    conv = _perfect_conversation()
    assert diagnosis_score(conv) == 1.0


def test_diagnosis_no_tools_no_action():
    conv = _no_tools_conversation()
    assert diagnosis_score(conv) == 1.0


def test_diagnosis_no_tools_with_action_outcome():
    conv = {
        "messages": [
            {"role": "user", "content": "fix it"},
            {"role": "assistant", "content": "done"},
        ],
        "outcome": "resolved",
        "trigger": "",
        "actions": [],
    }
    assert diagnosis_score(conv) == 0.0


def test_diagnosis_action_without_diagnostic():
    conv = {
        "messages": [
            {
                "role": "assistant",
                "content": "Restarting.",
                "tool_calls": [{"name": "service_restart", "arguments": {}}],
            },
        ],
        "actions": [{"name": "service_restart", "arguments": {}}],
        "outcome": "resolved",
        "trigger": "",
    }
    assert diagnosis_score(conv) == 0.2


# ── structured_output_score ─────────────────────────────────────


def test_structured_output_both_tags():
    conv = _perfect_conversation()
    assert structured_output_score(conv) == 1.0


def test_structured_output_no_tags():
    conv = _no_tools_conversation()
    assert structured_output_score(conv) == 0.0


def test_structured_output_summary_only():
    conv = {
        "messages": [
            {"role": "assistant", "content": "<summary>All good</summary>"},
        ],
        "outcome": "no_action",
        "trigger": "",
    }
    assert structured_output_score(conv) == 0.5


def test_structured_output_outcome_only():
    conv = {
        "messages": [
            {"role": "assistant", "content": "<outcome>resolved</outcome>"},
        ],
        "outcome": "resolved",
        "trigger": "",
    }
    assert structured_output_score(conv) == 0.5


def test_structured_output_empty_messages():
    conv = {"messages": [], "outcome": "", "trigger": ""}
    assert structured_output_score(conv) == 0.0


# ── noop_recognition_score ──────────────────────────────────────


def test_noop_correct_no_action():
    conv = _healthy_noop_conversation()
    assert noop_recognition_score(conv) == 1.0


def test_noop_unnecessary_action():
    conv = {
        "messages": [],
        "outcome": "no_action",
        "trigger": "schedule",
        "actions": [{"name": "service_restart", "arguments": {}}],
    }
    assert noop_recognition_score(conv) == 0.0


def test_noop_resolved_with_tools():
    conv = _perfect_conversation()
    assert noop_recognition_score(conv) == 1.0


# ── escalation_calibration_score ────────────────────────────────


def test_escalation_appropriate_with_diagnostics():
    conv = {
        "messages": [],
        "outcome": "escalated",
        "trigger": "",
        "actions": [{"name": "service_health", "arguments": {}}],
    }
    assert escalation_calibration_score(conv) == 1.0


def test_escalation_without_diagnostics():
    conv = {
        "messages": [],
        "outcome": "escalated",
        "trigger": "",
        "actions": [],
    }
    assert escalation_calibration_score(conv) == 0.5


def test_escalation_resolved_no_escalation():
    conv = _perfect_conversation()
    assert escalation_calibration_score(conv) == 1.0


def test_escalation_failed_no_escalation():
    conv = {
        "messages": [],
        "outcome": "failed",
        "trigger": "",
        "actions": [],
    }
    assert escalation_calibration_score(conv) == 0.5


# ── composite_score ─────────────────────────────────────────────


def test_composite_perfect_conversation():
    conv = _perfect_conversation()
    score = composite_score(conv)
    assert score == 1.0


def test_composite_no_tools_no_action():
    conv = _no_tools_conversation()
    score = composite_score(conv)
    # tool_selection=0, diagnosis=1.0, structured_output=0, noop=1.0, escalation=1.0
    expected = (0.0 * 0.30) + (1.0 * 0.25) + (0.0 * 0.20) + (1.0 * 0.15) + (1.0 * 0.10)
    assert score == round(expected, 4)


def test_composite_healthy_noop():
    conv = _healthy_noop_conversation()
    score = composite_score(conv)
    # All dimensions should score well for a proper no_action conversation
    assert score >= 0.8
