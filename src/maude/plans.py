# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Plan hygiene — active, aging, and stale plans.

Plans are implementation documents that live in ~/.claude/plans/. They
accumulate. Maude tracks their age and recommends cleanup.
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class PlanStatus:
    """Status of a single plan file."""

    path: Path
    modified: datetime
    age_days: float
    category: str  # "active", "aging", "stale"
    summary: str  # First non-empty line of the plan


def audit_plans(
    plans_dir: Path,
    aging_days: int = 7,
    stale_days: int = 30,
    now: datetime | None = None,
) -> list[PlanStatus]:
    """Audit plan files by age.

    Args:
        plans_dir: Directory containing plan .md files.
        aging_days: Days after which a plan is "aging".
        stale_days: Days after which a plan is "stale".
        now: Override current time (for testing).

    Returns:
        List of PlanStatus sorted by modification time (newest first).
    """
    if not plans_dir.is_dir():
        return []

    now = now or datetime.now(tz=timezone.utc)
    results: list[PlanStatus] = []

    for f in sorted(plans_dir.iterdir()):
        if not f.suffix == ".md" or not f.is_file():
            continue

        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc)
        age = (now - mtime).total_seconds() / 86400

        if age > stale_days:
            category = "stale"
        elif age > aging_days:
            category = "aging"
        else:
            category = "active"

        summary = _first_line(f)
        results.append(
            PlanStatus(
                path=f,
                modified=mtime,
                age_days=round(age, 1),
                category=category,
                summary=summary,
            )
        )

    results.sort(key=lambda p: p.modified, reverse=True)
    return results


def _first_line(path: Path) -> str:
    """Extract first non-empty, non-comment line from a markdown file."""
    try:
        for line in path.read_text().splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("<!--"):
                return stripped[:120]
    except OSError:
        return "(unreadable)"
    return "(empty)"
