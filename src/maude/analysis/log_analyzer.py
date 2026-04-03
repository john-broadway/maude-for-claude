# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Template-based log line pattern extraction and grouping.

Extracts normalized templates from raw log lines by replacing variable
parts (IPs, ports, UUIDs, timestamps, numbers) with placeholders.
Groups lines by template to surface the most frequent patterns.

No external NLP libraries -- pure Python string analysis.
"""

import re
from collections import defaultdict
from dataclasses import dataclass, field

# Template extraction regexes (order matters -- more specific first)
_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_ISO8601_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"
)
_SYSLOG_TS_RE = re.compile(
    r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}"
)
_IP_PORT_RE = re.compile(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+)\b")
_IP_RE = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")
_HEX_RE = re.compile(r"\b0x[0-9a-fA-F]{8,}\b|(?<![a-zA-Z])[0-9a-fA-F]{9,}(?![a-zA-Z])")
_QUOTED_RE = re.compile(r'"[^"]*"|\'[^\']*\'')
_NUM_RE = re.compile(r"\b\d{3,}\b")

# Severity keywords (lowercased)
_ERROR_KEYWORDS = frozenset({"error", "err", "fatal", "crit", "critical", "panic"})
_WARNING_KEYWORDS = frozenset({"warn", "warning"})


@dataclass
class LogPattern:
    """A group of log lines sharing the same normalized template."""

    template: str
    count: int
    severity: str  # "error", "warning", "info"
    examples: list[str] = field(default_factory=list)
    first_seen: str = ""
    last_seen: str = ""


class LogAnalyzer:
    """Extract and group log line patterns using template-based normalization."""

    def extract_template(self, line: str) -> str:
        """Replace variable parts of a log line with placeholders.

        Replacement order:
        1. UUIDs -> <UUID>
        2. ISO8601 timestamps -> <TS>
        3. Syslog timestamps -> <TS>
        4. IP:port pairs -> <IP>:<PORT>
        5. Standalone IPs -> <IP>
        6. Hex strings (>= 8 chars) -> <HEX>
        7. Quoted strings -> <STR>
        8. Numbers (> 2 digits) -> <NUM>
        """
        t = line
        t = _UUID_RE.sub("<UUID>", t)
        t = _ISO8601_RE.sub("<TS>", t)
        t = _SYSLOG_TS_RE.sub("<TS>", t)
        t = _IP_PORT_RE.sub("<IP>:<PORT>", t)
        t = _IP_RE.sub("<IP>", t)
        t = _HEX_RE.sub("<HEX>", t)
        t = _QUOTED_RE.sub("<STR>", t)
        t = _NUM_RE.sub("<NUM>", t)
        return t

    def analyze(self, lines: list[str]) -> list[LogPattern]:
        """Group log lines by extracted template.

        Returns list of LogPattern sorted by count descending.
        """
        groups: dict[str, list[str]] = defaultdict(list)
        for line in lines:
            if not line.strip():
                continue
            template = self.extract_template(line)
            groups[template].append(line)

        patterns: list[LogPattern] = []
        for template, examples in groups.items():
            first_ts = _extract_timestamp(examples[0])
            last_ts = _extract_timestamp(examples[-1])
            severity = _detect_severity(template)
            patterns.append(LogPattern(
                template=template,
                count=len(examples),
                severity=severity,
                examples=examples[:3],
                first_seen=first_ts,
                last_seen=last_ts,
            ))

        patterns.sort(key=lambda p: p.count, reverse=True)
        return patterns

    def top_patterns(self, lines: list[str], limit: int = 10) -> list[LogPattern]:
        """Return the most frequent patterns, capped at *limit*."""
        return self.analyze(lines)[:limit]


def _detect_severity(text: str) -> str:
    """Detect severity from keywords in the text."""
    lower = text.lower()
    for token in lower.split():
        # Strip common delimiters
        cleaned = token.strip("[](){}:,.")
        if cleaned in _ERROR_KEYWORDS:
            return "error"
        if cleaned in _WARNING_KEYWORDS:
            return "warning"
    return "info"


def _extract_timestamp(line: str) -> str:
    """Try to extract a timestamp from a log line."""
    m = _ISO8601_RE.search(line)
    if m:
        return m.group(0)
    m = _SYSLOG_TS_RE.search(line)
    if m:
        return m.group(0)
    return ""
