# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Full configuration sweep — Maude audits the entire house.

Orchestrates all audit functions into a single sweep report.
Scans infrastructure (agents, rules, skills, hooks), validates CLAUDE.md,
checks memory budget, and audits plan hygiene.
"""

import logging
from dataclasses import dataclass, field

from maude.claude_md import ClaudeMdReport, validate_claude_md
from maude.config import MaudeConfig
from maude.hooks import HookValidationReport, validate_hooks
from maude.memory_budget import MemoryBudgetReport, check_memory_budget
from maude.plans import PlanStatus, audit_plans

logger = logging.getLogger(__name__)


@dataclass
class InfraAudit:
    """Result of scanning agents, rules, and skills directories."""

    agent_count: int = 0
    rule_count: int = 0
    skill_count: int = 0
    agent_issues: list[str] = field(default_factory=list)
    rule_issues: list[str] = field(default_factory=list)
    skill_issues: list[str] = field(default_factory=list)


@dataclass
class SweepReport:
    """Complete configuration sweep result."""

    infra: InfraAudit = field(default_factory=InfraAudit)
    claude_md: ClaudeMdReport | None = None
    hooks: HookValidationReport = field(default_factory=HookValidationReport)
    memory: MemoryBudgetReport | None = None
    plans: list[PlanStatus] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    fixed: list[str] = field(default_factory=list)

    @property
    def all_clear(self) -> bool:
        return len(self.issues) == 0


def sweep(config: MaudeConfig | None = None) -> SweepReport:
    """Run a full configuration sweep.

    Args:
        config: MaudeConfig to use. Auto-detects if not provided.

    Returns:
        SweepReport with all audit results.
    """
    if config is None:
        config = MaudeConfig.auto_detect()

    report = SweepReport()
    logger.info("Maude sweep starting...")

    # Part A: Infrastructure audit
    report.infra = _audit_infra(config)
    report.issues.extend(report.infra.agent_issues)
    report.issues.extend(report.infra.rule_issues)
    report.issues.extend(report.infra.skill_issues)

    # Part B: CLAUDE.md quality
    report.claude_md = validate_claude_md(
        config.global_claude_md,
        project_root=config.project_root,
    )
    if report.claude_md.issues:
        report.issues.extend(f"CLAUDE.md: {issue}" for issue in report.claude_md.issues)

    # Part C: Hooks audit
    report.hooks = validate_hooks(config.settings_path)
    if report.hooks.issues:
        report.issues.extend(f"Hooks: {issue}" for issue in report.hooks.issues)

    # Part D: Memory budget
    mem_dir = config.memory_dir()
    if mem_dir:
        report.memory = check_memory_budget(mem_dir, config.memory_budget)
        if report.memory.status == "alert":
            report.issues.append(
                f"MEMORY.md at {report.memory.line_count} lines"
                f" — over {config.memory_budget}-line budget"
            )
        elif report.memory.status == "warning":
            report.issues.append(
                f"MEMORY.md at {report.memory.line_count} lines — approaching budget"
            )

    # Part E: Plan hygiene
    if config.plans_dir.is_dir():
        report.plans = audit_plans(
            config.plans_dir,
            aging_days=config.plan_aging_days,
            stale_days=config.plan_stale_days,
        )
        stale = [p for p in report.plans if p.category == "stale"]
        if stale:
            report.issues.append(f"{len(stale)} stale plan(s) — consider cleanup")

    logger.info(
        "Maude sweep complete: %d issues, %d fixed",
        len(report.issues),
        len(report.fixed),
    )
    return report


def _audit_infra(config: MaudeConfig) -> InfraAudit:
    """Scan agents, rules, and skills directories."""
    audit = InfraAudit()

    # Agents
    if config.agents_dir.is_dir():
        agents = list(config.agents_dir.glob("*.md"))
        audit.agent_count = len(agents)
        for a in agents:
            if a.stat().st_size == 0:
                audit.agent_issues.append(f"Empty agent: {a.name}")
    else:
        audit.agent_issues.append(f"Agents directory not found: {config.agents_dir}")

    # Rules
    if config.rules_dir.is_dir():
        rules = list(config.rules_dir.glob("*.md"))
        audit.rule_count = len(rules)
    else:
        audit.rule_issues.append(f"Rules directory not found: {config.rules_dir}")

    # Skills
    if config.skills_dir.is_dir():
        skills = [
            d for d in config.skills_dir.iterdir() if d.is_dir() and (d / "SKILL.md").exists()
        ]
        audit.skill_count = len(skills)
        for s in config.skills_dir.iterdir():
            if s.is_dir() and not (s / "SKILL.md").exists():
                # Check for alternate skill file patterns
                if not any(s.glob("*.md")):
                    audit.skill_issues.append(f"Skill missing SKILL.md: {s.name}")
    else:
        audit.skill_issues.append(f"Skills directory not found: {config.skills_dir}")

    return audit
