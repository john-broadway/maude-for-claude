# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Maude Token Estimation Tests
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for token estimation and context budget planning."""

from maude.llm.tokens import context_budget, estimate_tokens


def test_estimate_tokens_empty():
    assert estimate_tokens("") == 0


def test_estimate_tokens_short():
    assert estimate_tokens("hi") == 1  # min 1 token


def test_estimate_tokens_exact():
    # 20 chars / 4 = 5 tokens
    assert estimate_tokens("a" * 20) == 5


def test_estimate_tokens_realistic():
    text = "The quick brown fox jumps over the lazy dog"
    tokens = estimate_tokens(text)
    assert 8 <= tokens <= 15  # ~44 chars / 4 = 11


def test_context_budget_basic():
    budget = context_budget(
        system_prompt="You are a helpful assistant.",
        messages=[{"role": "user", "content": "Hello"}],
    )
    assert budget["used"] > 0
    assert budget["available"] > 0
    assert budget["used"] + budget["available"] == budget["max_context"]
    assert 0.0 < budget["utilization"] < 1.0
    assert "breakdown" in budget


def test_context_budget_with_tools():
    tools = [{"name": "test_tool", "description": "A test", "parameters": {}}]
    budget = context_budget(
        system_prompt="System",
        messages=[{"role": "user", "content": "Hi"}],
        tools=tools,
    )
    assert budget["breakdown"]["tools"] > 0


def test_context_budget_no_tools():
    budget = context_budget(
        system_prompt="System",
        messages=[{"role": "user", "content": "Hi"}],
    )
    assert budget["breakdown"]["tools"] == 0


def test_context_budget_custom_max():
    budget = context_budget(
        system_prompt="System",
        messages=[],
        max_context=4096,
    )
    assert budget["max_context"] == 4096


def test_context_budget_multipart_content():
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "Hello world"},
                {"type": "text", "text": "More text"},
            ],
        }
    ]
    budget = context_budget(system_prompt="", messages=messages)
    assert budget["breakdown"]["messages"] > 4  # more than just overhead


def test_context_budget_utilization_range():
    budget = context_budget(
        system_prompt="x" * 100000,
        messages=[{"role": "user", "content": "x" * 30000}],
        max_context=131072,
    )
    assert 0.0 < budget["utilization"] <= 1.0
