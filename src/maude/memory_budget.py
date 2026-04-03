# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Memory budget enforcement — MEMORY.md has a 200-line hard limit.

Lines beyond 200 are truncated from the system prompt. Maude watches the
budget and warns before content is silently lost.
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class MemoryBudgetReport:
    """Result of checking MEMORY.md against the line budget."""

    path: Path | None
    line_count: int = 0
    budget: int = 200
    status: str = "ok"  # "ok", "warning", "alert"
    supplementary_files: list[Path] = field(default_factory=list)
    supplementary_total_lines: int = 0

    @property
    def over_budget(self) -> bool:
        return self.line_count > self.budget


def check_memory_budget(
    memory_dir: Path,
    budget: int = 200,
    warning_threshold: int = 190,
) -> MemoryBudgetReport:
    """Check MEMORY.md line count against budget.

    Args:
        memory_dir: Path to the memory directory containing MEMORY.md.
        budget: Maximum lines before truncation (default 200).
        warning_threshold: Lines at which to warn (default 190).

    Returns:
        MemoryBudgetReport with line counts, status, and supplementary info.
    """
    memory_md = memory_dir / "MEMORY.md"
    if not memory_md.exists():
        logger.info("No MEMORY.md at %s", memory_md)
        return MemoryBudgetReport(path=None, budget=budget, status="ok")

    lines = memory_md.read_text().splitlines()
    line_count = len(lines)

    # Scan supplementary files (everything in memory_dir except MEMORY.md)
    supplementary: list[Path] = []
    supplementary_lines = 0
    if memory_dir.is_dir():
        for f in sorted(memory_dir.iterdir()):
            if f.name != "MEMORY.md" and f.suffix == ".md" and f.is_file():
                supplementary.append(f)
                supplementary_lines += len(f.read_text().splitlines())

    if line_count > budget:
        status = "alert"
        logger.warning(
            "MEMORY.md at %d lines — over %d-line budget. Content is being truncated.",
            line_count,
            budget,
        )
    elif line_count >= warning_threshold:
        status = "warning"
        logger.info("MEMORY.md at %d lines — approaching %d-line budget.", line_count, budget)
    else:
        status = "ok"

    return MemoryBudgetReport(
        path=memory_md,
        line_count=line_count,
        budget=budget,
        status=status,
        supplementary_files=supplementary,
        supplementary_total_lines=supplementary_lines,
    )
