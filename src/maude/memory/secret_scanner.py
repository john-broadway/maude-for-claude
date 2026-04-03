# Maude Memory Secret Scanner — redact secrets before cross-room sharing.
# Version: 1.0.0
# Created: 2026-04-02 15:30 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Scan memory text for secrets and redact before sharing.

Inspired by Claude Code's ``secretScanner.ts`` and ``teamMemSecretGuard.ts``
which scan memories before cross-agent sharing. Maude's relay and cross-room
queries share memories without checking for credentials or sensitive content.

Pattern-based scanner detects:
- API keys and tokens (Bearer, Basic, AWS, generic hex/base64)
- Passwords and connection strings
- PostgreSQL / Redis / SMTP credentials
- ITAR markings and export-control indicators
- Private keys and certificates

Redaction replaces matched content with ``[REDACTED]`` rather than blocking
the entire memory. An audit log entry is generated when redaction occurs.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

# ── Pattern definitions ──────────────────────────────────────────────
# Each pattern: (label, compiled regex, description)
# Patterns are applied in order; first match per region wins.

_PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    # API keys / tokens
    (
        "bearer_token",
        re.compile(r"Bearer\s+[A-Za-z0-9\-._~+/]+=*", re.IGNORECASE),
        "Bearer authentication token",
    ),
    (
        "basic_auth",
        re.compile(r"Basic\s+[A-Za-z0-9+/]+=*", re.IGNORECASE),
        "Basic authentication header",
    ),
    (
        "aws_key",
        re.compile(r"(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}"),
        "AWS access key ID",
    ),
    (
        "aws_secret",
        re.compile(r"(?:aws_secret_access_key|AWS_SECRET_ACCESS_KEY)\s*[=:]\s*\S+"),
        "AWS secret access key",
    ),
    (
        "github_token",
        re.compile(r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,255}"),
        "GitHub token",
    ),
    (
        "generic_api_key",
        re.compile(
            r"(?:api[_-]?key|apikey|api[_-]?token|access[_-]?token|secret[_-]?key)"
            r"\s*[=:]\s*['\"]?[A-Za-z0-9\-._~+/]{20,}['\"]?",
            re.IGNORECASE,
        ),
        "Generic API key/token assignment",
    ),
    # Passwords
    (
        "password_assign",
        re.compile(
            r"(?:password|passwd|pwd|pass)\s*[=:]\s*['\"]?[^\s'\"]{4,}['\"]?",
            re.IGNORECASE,
        ),
        "Password assignment",
    ),
    # Connection strings
    (
        "pg_connection",
        re.compile(
            r"postgres(?:ql)?://[^\s]+",
            re.IGNORECASE,
        ),
        "PostgreSQL connection string",
    ),
    (
        "redis_connection",
        re.compile(r"redis://[^\s]+", re.IGNORECASE),
        "Redis connection string",
    ),
    (
        "smtp_connection",
        re.compile(r"smtp://[^\s]+", re.IGNORECASE),
        "SMTP connection string",
    ),
    (
        "generic_connection",
        re.compile(
            r"(?:mongodb|mysql|amqp|nats)://[^\s]+",
            re.IGNORECASE,
        ),
        "Database/service connection string",
    ),
    # Private keys
    (
        "private_key",
        re.compile(r"-----BEGIN\s+(?:RSA\s+|EC\s+|DSA\s+|OPENSSH\s+)?PRIVATE\s+KEY-----"),
        "Private key header",
    ),
    # ITAR / export control
    (
        "itar_marking",
        re.compile(
            r"(?:ITAR|EAR|USML|CCL|export[- ]?control(?:led)?|defense[- ]?article"
            r"|technical[- ]?data|controlled[- ]?unclassified)"
            r"\s*(?:category|cat\.?|restricted|controlled|warning)?",
            re.IGNORECASE,
        ),
        "ITAR/export control marking",
    ),
    # Long hex strings (potential tokens/hashes — 40+ hex chars)
    (
        "hex_token",
        re.compile(r"(?<![A-Za-z0-9])[0-9a-fA-F]{40,}(?![A-Za-z0-9])"),
        "Long hex string (potential token/hash)",
    ),
]

REDACTION_MARKER = "[REDACTED]"


@dataclass
class ScanResult:
    """Result of scanning a text for secrets."""

    redacted_text: str
    had_secrets: bool = False
    findings: list[dict[str, str]] = field(default_factory=list)


def scan_text(text: str) -> ScanResult:
    """Scan text for secrets and return redacted version.

    Returns a ScanResult with the redacted text and a list of findings.
    Each finding includes the pattern label and description (not the
    matched content itself — that would defeat the purpose).
    """
    if not text:
        return ScanResult(redacted_text=text)

    findings: list[dict[str, str]] = []
    redacted = text

    for label, pattern, description in _PATTERNS:
        matches = list(pattern.finditer(redacted))
        if matches:
            for match in reversed(matches):  # reverse to preserve offsets
                redacted = redacted[: match.start()] + REDACTION_MARKER + redacted[match.end() :]
            findings.append(
                {"pattern": label, "description": description, "count": str(len(matches))}
            )

    return ScanResult(
        redacted_text=redacted,
        had_secrets=bool(findings),
        findings=findings,
    )


def redact_memory_fields(
    memory_dict: dict[str, object],
) -> tuple[dict[str, object], list[dict[str, str]]]:
    """Scan and redact sensitive fields in a memory dictionary.

    Scans: summary, trigger, reasoning, outcome.
    Does NOT scan: id, project, memory_type, created_at, tokens_used, model.

    Returns (redacted_dict, combined_findings).
    """
    scannable_fields = ("summary", "trigger", "reasoning", "outcome")
    all_findings: list[dict[str, str]] = []
    result = dict(memory_dict)  # shallow copy

    for field_name in scannable_fields:
        value = result.get(field_name)
        if isinstance(value, str) and value:
            scan = scan_text(value)
            if scan.had_secrets:
                result[field_name] = scan.redacted_text
                for finding in scan.findings:
                    finding["field"] = field_name
                all_findings.extend(scan.findings)

    return result, all_findings


def redact_memories(
    memories: list[dict[str, object]],
    project: str = "",
) -> list[dict[str, object]]:
    """Scan and redact a list of memory dictionaries for cross-room sharing.

    Logs a warning when redaction occurs (audit trail).
    Returns the list with redacted copies (originals unchanged).
    """
    redacted_list: list[dict[str, object]] = []
    total_findings = 0

    for mem in memories:
        redacted, findings = redact_memory_fields(mem)
        if findings:
            total_findings += len(findings)
        redacted_list.append(redacted)

    if total_findings:
        logger.warning(
            "SecretScanner: redacted %d finding(s) across %d memories for %s",
            total_findings,
            len(memories),
            project or "unknown",
        )

    return redacted_list
