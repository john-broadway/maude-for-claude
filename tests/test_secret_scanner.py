# Tests for memory secret scanner — redaction before cross-room sharing.
# Version: 1.0.0
# Created: 2026-04-02 15:40 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Tests for maude.memory.secret_scanner — pattern-based secret redaction."""

from maude.memory.secret_scanner import (
    REDACTION_MARKER,
    redact_memories,
    redact_memory_fields,
    scan_text,
)

# ── scan_text basics ─────────────────────────────────────────────────


def test_scan_empty_string():
    result = scan_text("")
    assert result.redacted_text == ""
    assert result.had_secrets is False
    assert result.findings == []


def test_scan_clean_text():
    text = "Service restarted successfully after disk alert"
    result = scan_text(text)
    assert result.redacted_text == text
    assert result.had_secrets is False


# ── Bearer / Basic auth ──────────────────────────────────────────────


def test_scan_bearer_token():
    text = "Authenticated with Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc"
    result = scan_text(text)
    assert result.had_secrets is True
    assert REDACTION_MARKER in result.redacted_text
    assert "eyJhbG" not in result.redacted_text


def test_scan_basic_auth():
    text = "Header: Basic dXNlcjpwYXNzd29yZA=="
    result = scan_text(text)
    assert result.had_secrets is True
    assert "dXNlcjpwYXNzd29yZA" not in result.redacted_text


# ── AWS keys ─────────────────────────────────────────────────────────


def test_scan_aws_access_key():
    text = "Key is AKIAIOSFODNN7EXAMPLE"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "AKIAIOSFODNN7EXAMPLE" not in result.redacted_text


def test_scan_aws_secret():
    text = "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "wJalrXUtnFEMI" not in result.redacted_text


# ── GitHub tokens ────────────────────────────────────────────────────


def test_scan_github_token():
    text = "Using token ghp_ABCDEFghijklmnopqrstuvwxyz0123456789"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "ghp_ABCDEF" not in result.redacted_text


# ── Generic API keys ─────────────────────────────────────────────────


def test_scan_api_key_assignment():
    text = "api_key = sk-1234567890abcdef1234567890abcdef"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "sk-1234567890" not in result.redacted_text


def test_scan_api_token_colon():
    text = "api_token: abc123def456ghi789jkl012mno345"
    result = scan_text(text)
    assert result.had_secrets is True


def test_scan_secret_key_quoted():
    text = "secret_key = 'my-very-secret-key-value-here'"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "my-very-secret" not in result.redacted_text


# ── Passwords ────────────────────────────────────────────────────────


def test_scan_password_equals():
    text = "password=hunter2"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "hunter2" not in result.redacted_text


def test_scan_passwd_colon():
    text = "passwd: my_secret_pwd_123"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "my_secret_pwd" not in result.redacted_text


# ── Connection strings ───────────────────────────────────────────────


def test_scan_postgres_uri():
    text = "Connected to postgresql://user:pass@192.0.2.30:5432/agent"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "user:pass" not in result.redacted_text


def test_scan_redis_uri():
    text = "Cache at redis://default:secret@192.0.2.33:6379/0"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "secret" not in result.redacted_text


def test_scan_mongodb_uri():
    text = "mongodb://admin:pass@mongo.internal:27017/db"
    result = scan_text(text)
    assert result.had_secrets is True


# ── Private keys ─────────────────────────────────────────────────────


def test_scan_private_key_header():
    text = "Found key: -----BEGIN RSA PRIVATE KEY-----\nMIIEpA..."
    result = scan_text(text)
    assert result.had_secrets is True
    assert "BEGIN RSA PRIVATE KEY" not in result.redacted_text


def test_scan_openssh_private_key():
    text = "-----BEGIN OPENSSH PRIVATE KEY-----"
    result = scan_text(text)
    assert result.had_secrets is True


# ── ITAR / export control ────────────────────────────────────────────


def test_scan_itar_marking():
    text = "This document is ITAR restricted"
    result = scan_text(text)
    assert result.had_secrets is True


def test_scan_export_controlled():
    text = "export-controlled technical data"
    result = scan_text(text)
    assert result.had_secrets is True


def test_scan_usml_category():
    text = "USML Category XI item"
    result = scan_text(text)
    assert result.had_secrets is True


def test_scan_defense_article():
    text = "defense article restricted"
    result = scan_text(text)
    assert result.had_secrets is True


# ── Hex tokens ───────────────────────────────────────────────────────


def test_scan_long_hex_token():
    text = "Token: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "a1b2c3d4e5f6" not in result.redacted_text


def test_scan_short_hex_not_flagged():
    """Short hex strings (< 40 chars) are not flagged — too many false positives."""
    text = "Error code: 0xDEADBEEF"
    result = scan_text(text)
    # Short hex should NOT trigger
    assert "0xDEADBEEF" in result.redacted_text


# ── Multiple secrets in one text ─────────────────────────────────────


def test_scan_multiple_secrets():
    text = "password=secret123 and api_key=abcdefghijklmnopqrstuvwxyz"
    result = scan_text(text)
    assert result.had_secrets is True
    assert "secret123" not in result.redacted_text
    assert result.redacted_text.count(REDACTION_MARKER) >= 2


# ── redact_memory_fields ─────────────────────────────────────────────


def test_redact_memory_fields_clean():
    mem = {
        "id": 42,
        "summary": "Service restarted",
        "trigger": "health_loop",
        "reasoning": "Disk was high",
        "outcome": "resolved",
    }
    redacted, findings = redact_memory_fields(mem)
    assert findings == []
    assert redacted["summary"] == "Service restarted"


def test_redact_memory_fields_with_secret():
    mem = {
        "id": 42,
        "summary": "Connected to postgresql://admin:pass@db:5432/main",
        "trigger": "health_loop",
        "reasoning": "Used password=secret123",
        "outcome": "resolved",
    }
    redacted, findings = redact_memory_fields(mem)
    assert len(findings) >= 2
    assert "admin:pass" not in redacted["summary"]
    assert "secret123" not in redacted["reasoning"]
    # Non-scannable fields untouched
    assert redacted["id"] == 42
    assert redacted["outcome"] == "resolved"


def test_redact_memory_fields_preserves_original():
    """Original dict is not mutated."""
    mem = {"summary": "password=hunter2", "trigger": "test"}
    redacted, _ = redact_memory_fields(mem)
    assert "hunter2" in mem["summary"]  # original unchanged
    assert "hunter2" not in redacted["summary"]


# ── redact_memories (list) ───────────────────────────────────────────


def test_redact_memories_empty():
    assert redact_memories([]) == []


def test_redact_memories_mixed(caplog):
    memories = [
        {"summary": "Clean memory", "outcome": "ok"},
        {"summary": "password=secret", "outcome": "ok"},
    ]
    result = redact_memories(memories, project="grafana")
    assert len(result) == 2
    assert result[0]["summary"] == "Clean memory"
    assert "secret" not in result[1]["summary"]
    assert "SecretScanner" in caplog.text


def test_redact_memories_does_not_mutate_originals():
    memories = [{"summary": "api_key=AAAA_BBBB_CCCC_DDDD_EEEE_FFFF"}]
    result = redact_memories(memories)
    assert "AAAA_BBBB" in memories[0]["summary"]  # original
    assert "AAAA_BBBB" not in result[0]["summary"]  # redacted
