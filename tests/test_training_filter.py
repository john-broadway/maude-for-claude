# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.runtime.training_filter — ITAR, PII, quality, language."""

from maude.healing.training.filter import (
    REDACTED,
    TrainingFilterConfig,
    check_itar,
    check_quality,
    filter_conversation,
    scrub_pii,
)

# ── ITAR detection ────────────────────────────────────────────


def test_itar_detects_usml():
    msgs = [{"role": "user", "content": "This part is USML Category XII"}]
    assert check_itar(msgs, ["USML"]) is True


def test_itar_detects_case_insensitive():
    msgs = [{"role": "assistant", "content": "It is itar controlled data."}]
    assert check_itar(msgs, ["ITAR"]) is True


def test_itar_clean_conversation():
    msgs = [
        {"role": "user", "content": "What's the monitoring status?"},
        {"role": "assistant", "content": "All dashboards are healthy."},
    ]
    assert check_itar(msgs, ["USML", "ITAR"]) is False


def test_itar_multi_pattern():
    msgs = [{"role": "user", "content": "Check EAR99 classification"}]
    assert check_itar(msgs, ["USML", "ITAR", "EAR99"]) is True


def test_itar_skips_non_string_content():
    msgs = [{"role": "user", "content": [{"type": "tool_result"}]}]
    assert check_itar(msgs, ["ITAR"]) is False


# ── PII scrubbing ─────────────────────────────────────────────


def test_scrub_email():
    msgs = [{"role": "user", "content": "Contact user@company.com for details"}]
    result = scrub_pii(msgs)
    assert REDACTED in result[0]["content"]
    assert "user@company.com" not in result[0]["content"]


def test_scrub_phone():
    msgs = [{"role": "assistant", "content": "Call 801-555-1234 for support"}]
    result = scrub_pii(msgs)
    assert REDACTED in result[0]["content"]
    assert "801-555-1234" not in result[0]["content"]


def test_scrub_ssn():
    msgs = [{"role": "user", "content": "SSN is 123-45-6789"}]
    result = scrub_pii(msgs)
    assert REDACTED in result[0]["content"]
    assert "123-45-6789" not in result[0]["content"]


def test_scrub_preserves_clean_text():
    msgs = [{"role": "user", "content": "What is the disk usage?"}]
    result = scrub_pii(msgs)
    assert result[0]["content"] == "What is the disk usage?"


def test_scrub_multiple_pii():
    msgs = [{"role": "user", "content": "Email: a@b.com, Phone: 555-123-4567"}]
    result = scrub_pii(msgs)
    assert result[0]["content"].count(REDACTED) == 2


def test_scrub_preserves_non_string_content():
    msgs = [{"role": "user", "content": [{"type": "tool_result"}]}]
    result = scrub_pii(msgs)
    assert result[0]["content"] == [{"type": "tool_result"}]


# ── Quality gate ──────────────────────────────────────────────


def test_quality_passes_good_conversation():
    msgs = [
        {"role": "user", "content": "Check monitoring health"},
        {"role": "assistant", "content": "Grafana is healthy."},
    ]
    assert check_quality(msgs, min_messages=2, error_phrases=[]) is True


def test_quality_fails_too_short():
    msgs = [{"role": "user", "content": "hi"}]
    assert check_quality(msgs, min_messages=2, error_phrases=[]) is False


def test_quality_fails_error_response():
    msgs = [
        {"role": "user", "content": "Check health"},
        {"role": "assistant", "content": "All LLM backends unavailable."},
    ]
    assert (
        check_quality(
            msgs,
            min_messages=2,
            error_phrases=["All LLM backends unavailable"],
        )
        is False
    )


def test_quality_passes_when_error_not_last_assistant():
    msgs = [
        {"role": "assistant", "content": "All LLM backends unavailable."},
        {"role": "user", "content": "try again"},
        {"role": "assistant", "content": "Grafana is healthy now."},
    ]
    assert (
        check_quality(
            msgs,
            min_messages=2,
            error_phrases=["All LLM backends unavailable"],
        )
        is True
    )


# ── Full filter pipeline ──────────────────────────────────────


def test_filter_passes_clean_conversation():
    msgs = [
        {"role": "user", "content": "Room status?"},
        {"role": "assistant", "content": "All rooms are healthy."},
    ]
    result = filter_conversation(msgs)
    assert result is not None
    assert len(result) == 2


def test_filter_excludes_itar():
    msgs = [
        {"role": "user", "content": "What's the USML category?"},
        {"role": "assistant", "content": "Category XII."},
    ]
    assert filter_conversation(msgs) is None


def test_filter_scrubs_pii():
    msgs = [
        {"role": "user", "content": "Email john@example.com about the outage"},
        {"role": "assistant", "content": "I'll contact them."},
    ]
    result = filter_conversation(msgs)
    assert result is not None
    assert "john@example.com" not in result[0]["content"]
    assert REDACTED in result[0]["content"]


def test_filter_excludes_short_conversations():
    msgs = [{"role": "user", "content": "hi"}]
    assert filter_conversation(msgs) is None


def test_filter_custom_config():
    cfg = TrainingFilterConfig(itar_patterns=["SECRET_WORD"], min_messages=1)
    msgs = [{"role": "user", "content": "This contains SECRET_WORD"}]
    assert filter_conversation(msgs, cfg) is None


def test_filter_config_from_dict():
    cfg = TrainingFilterConfig.from_dict(
        {
            "itar_patterns": ["CUSTOM"],
            "min_messages": 3,
        }
    )
    assert cfg.itar_patterns == ["CUSTOM"]
    assert cfg.min_messages == 3


def test_filter_config_from_none():
    cfg = TrainingFilterConfig.from_dict(None)
    assert cfg.min_messages == 2
    assert "USML" in cfg.itar_patterns
