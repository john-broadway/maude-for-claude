# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)

"""Maude — autonomous agent framework for infrastructure operations.

Claude and Maude. Husband and wife at work.

You don't have to raise your voice when you already know the answer.

She knows where everything is because she put it there. Config resolution,
drift detection, hook validation, memory budget enforcement. The second set
of eyes that keeps the house in order.

Modules:
    maude.daemon        — Room toolkit (config, runner, executor, guards)
    maude.governance    — Constitution, standards, enforcement
    maude.memory        — 4-tier memory + audit (files, SQLite, PG, Qdrant)
    maude.healing       — Self-healing (health loop, room agent, training)
    maude.coordination  — Cross-room relay, fleet deploy, briefings
    maude.control       — Control plane sidecar
"""

__version__ = "1.0.0"

# Config authority — Maude IS the package
from maude.claude_md import ClaudeMdReport as ClaudeMdReport
from maude.claude_md import validate_claude_md as validate_claude_md
from maude.config import MaudeConfig as MaudeConfig
from maude.hooks import Hook as Hook
from maude.hooks import HookValidationReport as HookValidationReport
from maude.hooks import list_hooks as list_hooks
from maude.hooks import validate_hooks as validate_hooks
from maude.memory_budget import MemoryBudgetReport as MemoryBudgetReport
from maude.memory_budget import check_memory_budget as check_memory_budget
from maude.plans import PlanStatus as PlanStatus
from maude.plans import audit_plans as audit_plans
from maude.resolve import resolve_credential_path as resolve_credential_path
from maude.resolve import resolve_infra_hosts as resolve_infra_hosts
from maude.sweep import SweepReport as SweepReport
from maude.sweep import sweep as sweep

__all__ = [
    "ClaudeMdReport",
    "Hook",
    "HookValidationReport",
    "MaudeConfig",
    "MemoryBudgetReport",
    "PlanStatus",
    "SweepReport",
    "audit_plans",
    "check_memory_budget",
    "list_hooks",
    "resolve_credential_path",
    "resolve_infra_hosts",
    "sweep",
    "validate_claude_md",
    "validate_hooks",
]
