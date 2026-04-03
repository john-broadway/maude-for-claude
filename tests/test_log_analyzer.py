# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for LogAnalyzer — template extraction and pattern grouping."""

from maude.analysis.log_analyzer import LogAnalyzer

# ── extract_template ──────────────────────────────────────────────


def test_extract_template_replaces_ip():
    la = LogAnalyzer()
    result = la.extract_template("Connection refused to 192.168.1.50")
    assert "<IP>" in result
    assert "192.168.1.50" not in result


def test_extract_template_replaces_ip_and_port():
    la = LogAnalyzer()
    result = la.extract_template("Connection refused to 192.168.1.50:5432")
    assert "<IP>:<PORT>" in result
    assert "192.168.1.50" not in result
    assert "5432" not in result


def test_extract_template_replaces_uuid():
    la = LogAnalyzer()
    line = "Request a1b3c4d5-e123-4567-89ab-cdef01234567 failed"
    result = la.extract_template(line)
    assert "<UUID>" in result


def test_extract_template_replaces_iso8601_timestamp():
    la = LogAnalyzer()
    line = "2026-02-08T16:00:00Z service started"
    result = la.extract_template(line)
    assert "<TS>" in result
    assert "2026-02-08" not in result


def test_extract_template_replaces_syslog_timestamp():
    la = LogAnalyzer()
    line = "Feb  8 16:00:00 myhost sshd[1234]: connection accepted"
    result = la.extract_template(line)
    assert "<TS>" in result
    assert "Feb  8" not in result


def test_extract_template_replaces_numbers():
    la = LogAnalyzer()
    line = "Processed 12345 records in 456 seconds"
    result = la.extract_template(line)
    assert "<NUM>" in result
    assert "12345" not in result
    assert "456" not in result


def test_extract_template_preserves_short_numbers():
    la = LogAnalyzer()
    # Numbers <= 2 digits should NOT be replaced
    line = "retry attempt 2 of 10"
    result = la.extract_template(line)
    assert "2" in result
    assert "10" in result


def test_extract_template_replaces_hex_strings():
    la = LogAnalyzer()
    line = "Hash: 0xdeadbeef01234567 computed"
    result = la.extract_template(line)
    assert "<HEX>" in result


def test_extract_template_replaces_quoted_strings():
    la = LogAnalyzer()
    line = 'Failed to connect to "primary-db" at host'
    result = la.extract_template(line)
    assert "<STR>" in result
    assert "primary-db" not in result


def test_extract_template_multiple_replacements():
    la = LogAnalyzer()
    line = "2026-02-08T12:00:00Z Connection to 192.168.1.50:5432 failed after 1500 ms"
    result = la.extract_template(line)
    assert "<TS>" in result
    assert "<IP>:<PORT>" in result
    assert "<NUM>" in result


# ── severity detection ────────────────────────────────────────────


def test_severity_error_keyword():
    la = LogAnalyzer()
    lines = ["ERROR: something broke"]
    patterns = la.analyze(lines)
    assert patterns[0].severity == "error"


def test_severity_fatal_keyword():
    la = LogAnalyzer()
    lines = ["[FATAL] process crashed"]
    patterns = la.analyze(lines)
    assert patterns[0].severity == "error"


def test_severity_warning_keyword():
    la = LogAnalyzer()
    lines = ["WARNING: disk space low"]
    patterns = la.analyze(lines)
    assert patterns[0].severity == "warning"


def test_severity_info_default():
    la = LogAnalyzer()
    lines = ["service started successfully"]
    patterns = la.analyze(lines)
    assert patterns[0].severity == "info"


# ── analyze ───────────────────────────────────────────────────────


def test_analyze_groups_similar_lines():
    la = LogAnalyzer()
    lines = [
        "Connection refused to localhost:5432",
        "Connection refused to localhost:6333",
        "Connection refused to localhost:6379",
        "Service started on port 8080",
    ]
    patterns = la.analyze(lines)
    # The 3 connection lines should share a template
    connection_pattern = next(p for p in patterns if "Connection refused" in p.template)
    assert connection_pattern.count == 3
    assert len(connection_pattern.examples) == 3


def test_analyze_skips_empty_lines():
    la = LogAnalyzer()
    lines = ["", "  ", "actual log line"]
    patterns = la.analyze(lines)
    assert len(patterns) == 1


def test_analyze_timestamps_extracted():
    la = LogAnalyzer()
    lines = [
        "2026-01-01T00:00:00Z service restarted",
        "2026-01-02T12:00:00Z service restarted",
    ]
    patterns = la.analyze(lines)
    pattern = patterns[0]
    assert pattern.first_seen == "2026-01-01T00:00:00Z"
    assert pattern.last_seen == "2026-01-02T12:00:00Z"


def test_analyze_returns_sorted_by_count():
    la = LogAnalyzer()
    lines = [
        "event A happened",
        "event B happened",
        "event B happened",
        "event B happened",
        "event C happened",
        "event C happened",
    ]
    patterns = la.analyze(lines)
    counts = [p.count for p in patterns]
    assert counts == sorted(counts, reverse=True)


# ── top_patterns ──────────────────────────────────────────────────


def test_top_patterns_limits_results():
    la = LogAnalyzer()
    lines = [f"unique event type {i} occurred" for i in range(100, 120)]
    patterns = la.top_patterns(lines, limit=5)
    assert len(patterns) <= 5


def test_top_patterns_sorted_by_count():
    la = LogAnalyzer()
    lines = (
        ["frequent event happened"] * 10
        + ["rare event happened"] * 2
        + ["medium event happened"] * 5
    )
    patterns = la.top_patterns(lines, limit=3)
    assert patterns[0].count >= patterns[1].count
    assert patterns[1].count >= patterns[2].count
