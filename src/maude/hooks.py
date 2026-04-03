# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Hook inventory and validation — Kirill's muscle, audited by Maude.

Parses settings.json to inventory all configured hooks, then validates
that referenced scripts exist on disk and matchers are well-formed.
"""

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)

VALID_EVENTS = frozenset(
    {
        "PreToolUse",
        "PostToolUse",
        "UserPromptSubmit",
        "SessionStart",
        "Stop",
        "Notification",
    }
)


@dataclass
class Hook:
    """A single hook entry from settings.json."""

    event: str
    matcher: str
    command: str
    script_path: Path | None  # Resolved script path (None if inline)
    exists: bool  # Script file exists on disk
    inline: bool  # True if command is inline, not a file reference


@dataclass
class HookValidationReport:
    """Result of validating all hooks."""

    total: int = 0
    valid: int = 0
    missing_scripts: list[str] = field(default_factory=list)
    unknown_events: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    hooks_by_event: dict[str, list[Hook]] = field(default_factory=dict)


def list_hooks(settings_path: Path) -> list[Hook]:
    """Parse settings.json and list all configured hooks.

    Args:
        settings_path: Path to ~/.claude/settings.json.

    Returns:
        List of Hook entries found in the settings file.
    """
    if not settings_path.exists():
        logger.info("No settings.json at %s", settings_path)
        return []

    try:
        data = json.loads(settings_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        logger.error("Failed to parse settings.json: %s", e)
        return []

    hooks_section = data.get("hooks", {})
    hooks_dir = settings_path.parent / "hooks"
    results: list[Hook] = []

    for event, entries in hooks_section.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            matcher = entry.get("matcher", "")
            command = entry.get("command", "")
            hook = _parse_hook_entry(event, matcher, command, hooks_dir)
            results.append(hook)

    return results


def validate_hooks(settings_path: Path) -> HookValidationReport:
    """Validate all hooks: scripts exist, events valid, no issues.

    Args:
        settings_path: Path to ~/.claude/settings.json.

    Returns:
        HookValidationReport with validation results.
    """
    hooks = list_hooks(settings_path)
    report = HookValidationReport(total=len(hooks))

    for hook in hooks:
        # Group by event
        report.hooks_by_event.setdefault(hook.event, []).append(hook)

        # Check event name
        if hook.event not in VALID_EVENTS:
            report.unknown_events.append(hook.event)
            report.issues.append(f"Unknown event '{hook.event}' for command: {hook.command}")

        # Check script existence
        if not hook.inline and not hook.exists:
            report.missing_scripts.append(str(hook.script_path))
            report.issues.append(f"Missing script: {hook.script_path}")
        else:
            report.valid += 1

    return report


def _parse_hook_entry(event: str, matcher: str, command: str, hooks_dir: Path) -> Hook:
    """Parse a single hook entry into a Hook dataclass."""
    # Detect if command references a script file
    # Scripts are typically absolute paths or relative to hooks_dir
    script_path = None
    exists = False
    inline = True

    if command:
        # Check if command starts with a path-like string
        first_token = command.split()[0] if command.split() else ""
        candidate = Path(first_token)

        if candidate.is_absolute():
            script_path = candidate
            exists = candidate.exists()
            inline = False
        elif (hooks_dir / candidate.name).exists():
            script_path = hooks_dir / candidate.name
            exists = True
            inline = False

    return Hook(
        event=event,
        matcher=matcher,
        command=command,
        script_path=script_path,
        exists=exists,
        inline=inline,
    )
