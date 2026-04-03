# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""CLAUDE.md quality validation — this is why we have standards, dear.

Checks that CLAUDE.md files have proper structure: version header,
valid file references, and no stale pointers to files that don't exist.
"""

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)

# Patterns for detecting file references in markdown
_FILE_REF_PATTERN = re.compile(r"`([~./][\w/.{}\-*]+)`")
_VERSION_PATTERN = re.compile(r"[Vv]ersion[:\s]+(\d+\.\d+(?:\.\d+)?)")


@dataclass
class ClaudeMdReport:
    """Result of validating a CLAUDE.md file."""

    path: Path
    exists: bool = True
    has_version: bool = False
    version: str = ""
    line_count: int = 0
    stale_references: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)


def validate_claude_md(
    path: Path,
    project_root: Path | None = None,
) -> ClaudeMdReport:
    """Validate CLAUDE.md quality.

    Checks:
    - File exists
    - Has a version header
    - File references point to real files (where resolvable)

    Args:
        path: Path to the CLAUDE.md file.
        project_root: Project root for resolving relative paths.

    Returns:
        ClaudeMdReport with findings.
    """
    report = ClaudeMdReport(path=path)

    if not path.exists():
        report.exists = False
        report.issues.append(f"CLAUDE.md not found at {path}")
        return report

    content = path.read_text()
    lines = content.splitlines()
    report.line_count = len(lines)

    # Check for version header
    for line in lines[:20]:
        match = _VERSION_PATTERN.search(line)
        if match:
            report.has_version = True
            report.version = match.group(1)
            break

    if not report.has_version:
        report.issues.append("Missing version header in first 20 lines")

    # Check file references (only if we have a project root to resolve against)
    if project_root:
        refs = _FILE_REF_PATTERN.findall(content)
        for ref in refs:
            # Skip glob patterns, env vars, and obvious non-paths
            if "*" in ref or "{" in ref or "$" in ref:
                continue
            # Expand ~ to home
            resolved = Path(ref).expanduser()
            if not resolved.is_absolute():
                resolved = project_root / resolved
            if not resolved.exists() and not _is_example_path(ref):
                report.stale_references.append(ref)

    if report.stale_references:
        report.issues.append(f"{len(report.stale_references)} stale file reference(s)")

    return report


def _is_example_path(ref: str) -> bool:
    """Check if a path reference looks like an example/placeholder."""
    examples = {"your-fork", "example", "my-service", "my-room", "project_mcp"}
    return any(ex in ref.lower() for ex in examples)
