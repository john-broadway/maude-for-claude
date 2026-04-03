# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Maude's configuration — she knows where everything is because she put it there.

Paths, thresholds, and project discovery for the configuration authority.
Tied to Claude Code by design — Maude and Claude, husband and wife at work.
"""

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class MaudeConfig:
    """Configuration for the Maude configuration authority.

    Auto-detects Claude Code paths from the environment. Override any
    field for testing or non-standard layouts.

    Args:
        claude_home: Path to ~/.claude/ (global Claude Code config).
        project_root: Current project root (contains .claude/ dir).
        memory_budget: MEMORY.md line limit before truncation from system prompt.
        plan_stale_days: Plans older than this are stale.
        plan_aging_days: Plans older than this are aging.
    """

    claude_home: Path = field(default_factory=lambda: Path.home() / ".claude")
    project_root: Path | None = None
    memory_budget: int = 200
    plan_stale_days: int = 30
    plan_aging_days: int = 7

    @classmethod
    def auto_detect(cls) -> "MaudeConfig":
        """Auto-detect paths from environment and cwd.

        Walks up from cwd looking for .claude/ or .git/ to find project root.
        """
        claude_home = Path(os.environ.get("CLAUDE_HOME", Path.home() / ".claude"))
        project_root = _find_project_root(Path.cwd())
        cfg = cls(claude_home=claude_home, project_root=project_root)
        logger.info("Maude config: claude_home=%s, project_root=%s", claude_home, project_root)
        return cfg

    @property
    def settings_path(self) -> Path:
        """Path to settings.json."""
        return self.claude_home / "settings.json"

    @property
    def agents_dir(self) -> Path:
        """Path to global agents directory."""
        return self.claude_home / "agents"

    @property
    def rules_dir(self) -> Path:
        """Path to global rules directory."""
        return self.claude_home / "rules"

    @property
    def skills_dir(self) -> Path:
        """Path to global skills directory."""
        return self.claude_home / "skills"

    @property
    def hooks_dir(self) -> Path:
        """Path to hook scripts directory."""
        return self.claude_home / "hooks"

    @property
    def plans_dir(self) -> Path:
        """Path to plans directory."""
        return self.claude_home / "plans"

    @property
    def global_claude_md(self) -> Path:
        """Path to global CLAUDE.md."""
        return self.claude_home / "CLAUDE.md"

    @property
    def project_claude_md(self) -> Path | None:
        """Path to project-level CLAUDE.md, if project root exists."""
        if self.project_root:
            p = self.project_root / ".claude" / "CLAUDE.md"
            return p if p.exists() else None
        return None

    def memory_dir(self, project_key: str | None = None) -> Path | None:
        """Path to auto memory directory for a project.

        The project_key is the mangled path Claude Code uses, e.g.
        '-home-hp-projects-the-maude'. If not provided, attempts
        to derive from project_root.
        """
        if project_key:
            d = self.claude_home / "projects" / project_key / "memory"
            return d if d.exists() else None
        if self.project_root:
            mangled = str(self.project_root).replace("/", "-").lstrip("-")
            d = self.claude_home / "projects" / mangled / "memory"
            return d if d.exists() else None
        return None


def _find_project_root(start: Path) -> Path | None:
    """Walk up from start looking for .claude/ or .git/ directory."""
    current = start.resolve()
    for _ in range(20):  # safety limit
        if (current / ".claude").is_dir() or (current / ".git").is_dir():
            return current
        parent = current.parent
        if parent == current:
            break
        current = parent
    return None
