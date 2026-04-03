# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Maude Admin Registry — Autonomous actions and guardrails
#          Claude (Anthropic) <noreply@anthropic.com>
"""Autonomous admin action registry and guardrails for Rooms.

Defines which administrative actions a Room can take autonomously (without
human confirmation) and which actions are guarded (require escalation).

The distinction is self-preservation, not command severity:
    Autonomous: restart service, clear cache, delete tmp, kill process, rotate logs
    Guarded:    stop own service, modify own config, cross-room operations, data loss

Config-driven via ``autonomous_admin`` section in config.yaml.

Example config::

    autonomous_admin:
      enabled: true
      allowed_actions:
        - restart_service
        - clear_cache
        - delete_tmp
        - kill_process
        - vacuum_db
        - rotate_logs
      guardrails:
        - no_self_stop
        - no_config_mutation
        - no_cross_room
        - no_data_destruction
      custom_actions:
        - name: vacuum_chunks
          command: "SELECT run_maintenance_policy()"
          description: "Run TimescaleDB maintenance"
"""

import logging
import re
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

# Universal guardrails — these cannot be overridden by config
BUILTIN_GUARDRAILS = {
    "no_self_stop": "Cannot stop or disable own service",
    "no_config_mutation": "Cannot modify own configuration files",
    "no_cross_room": "Cannot affect other rooms' services or data",
    "no_data_destruction": "Cannot delete non-ephemeral data",
}

_SELF_STOP_PATTERNS = [
    r"systemctl\s+(stop|disable)\s+maude@",
    r"systemctl\s+(stop|disable)\s+{service}",
    r"kill\s+-9\s+.*maude",
    r"rm\s+.*maude\.env",
    r"rm\s+.*config\.yaml",
    r"rm\s+.*config-local\.yaml",
]

_CONFIG_MUTATION_PATTERNS = [
    r"(cat|echo|tee|sed|awk).*>.*maude\.env",
    r"(cat|echo|tee|sed|awk).*>.*config\.yaml",
    r"(cat|echo|tee|sed|awk).*>.*config-local\.yaml",
    r"(cat|echo|tee|sed|awk).*>?.*/etc/maude/",
]

_DATA_DESTRUCTION_PATTERNS = [
    r"rm\s+-rf?\s+/var/lib/maude/",
    r"rm\s+-rf?\s+/app/",
    r"DROP\s+(TABLE|DATABASE)",
    r"TRUNCATE\s+",
    r"DELETE\s+FROM\s+(?!.*WHERE)",
]


@dataclass
class AdminAction:
    """A defined administrative action."""

    name: str
    description: str = ""
    command_template: str = ""


@dataclass
class GuardrailResult:
    """Result of a guardrail check."""

    allowed: bool
    guardrail: str = ""
    reason: str = ""


@dataclass
class AdminRegistryConfig:
    """Parsed autonomous admin configuration."""

    enabled: bool = False
    allowed_actions: set[str] = field(default_factory=set)
    guardrails: list[str] = field(default_factory=list)
    custom_actions: list[dict[str, Any]] = field(default_factory=list)
    min_pattern_confidence: float = 0.75
    min_pattern_occurrences: int = 3

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> "AdminRegistryConfig":
        if not data:
            return cls()
        return cls(
            enabled=data.get("enabled", False),
            allowed_actions=set(data.get("allowed_actions", [])),
            guardrails=data.get("guardrails", list(BUILTIN_GUARDRAILS.keys())),
            custom_actions=data.get("custom_actions", []),
            min_pattern_confidence=data.get("min_pattern_confidence", 0.75),
            min_pattern_occurrences=data.get("min_pattern_occurrences", 3),
        )


class AdminRegistry:
    """Action registry and guardrail enforcer for autonomous Room administration.

    Answers: "Can this Room do this action without asking?"

    Standard actions any room can be granted:
        restart_service, clear_cache, delete_tmp, kill_process,
        vacuum_db, rotate_logs, prune_stale, cleanup_old_backups
    """

    STANDARD_ACTIONS = frozenset(
        {
            "restart_service",
            "clear_cache",
            "delete_tmp",
            "kill_process",
            "vacuum_db",
            "rotate_logs",
            "prune_stale",
            "cleanup_old_backups",
        }
    )

    def __init__(
        self,
        config: AdminRegistryConfig,
        service_name: str,
        project: str,
    ) -> None:
        self.config = config
        self.service_name = service_name
        self.project = project
        self._custom_actions: dict[str, AdminAction] = {}

        for ca in config.custom_actions:
            action = AdminAction(
                name=ca["name"],
                description=ca.get("description", ""),
                command_template=ca.get("command", ""),
            )
            self._custom_actions[action.name] = action

    @property
    def enabled(self) -> bool:
        return self.config.enabled

    def is_allowed(self, action_name: str) -> bool:
        """Check if an action is in the allowed set."""
        if not self.config.enabled:
            return False
        return action_name in self.config.allowed_actions or action_name in self._custom_actions

    def check_guardrails(
        self,
        action_name: str,
        command: str = "",
    ) -> GuardrailResult:
        """Check all guardrails against a proposed action.

        Even if the action is in allowed_actions, guardrails can block it.
        Guardrails are the Constitutional floor — they protect the Room
        from self-harm and sovereignty violations.
        """
        if not self.config.enabled:
            return GuardrailResult(
                allowed=False,
                guardrail="disabled",
                reason="Autonomous admin disabled",
            )

        if not self.is_allowed(action_name):
            return GuardrailResult(
                allowed=False,
                guardrail="not_allowed",
                reason=f"Action '{action_name}' not in allowed_actions",
            )

        if not command:
            return GuardrailResult(allowed=True)

        # no_self_stop: can't stop/disable own service
        if "no_self_stop" in self.config.guardrails:
            for pattern in _SELF_STOP_PATTERNS:
                compiled = pattern.replace(
                    "{service}",
                    re.escape(self.service_name),
                )
                if re.search(compiled, command, re.IGNORECASE):
                    return GuardrailResult(
                        allowed=False,
                        guardrail="no_self_stop",
                        reason=f"Self-harm: matches '{pattern}'",
                    )

        # no_config_mutation: can't modify own config
        if "no_config_mutation" in self.config.guardrails:
            for pattern in _CONFIG_MUTATION_PATTERNS:
                if re.search(pattern, command, re.IGNORECASE):
                    return GuardrailResult(
                        allowed=False,
                        guardrail="no_config_mutation",
                        reason=f"Config mutation: matches '{pattern}'",
                    )

        # no_cross_room: can't touch other rooms' services
        if "no_cross_room" in self.config.guardrails:
            cross_pattern = r"maude@(?!{project}\b)".replace(
                "{project}",
                re.escape(self.project),
            )
            if re.search(cross_pattern, command):
                return GuardrailResult(
                    allowed=False,
                    guardrail="no_cross_room",
                    reason="Cross-room operation detected",
                )

        # no_data_destruction: can't destroy persistent data
        if "no_data_destruction" in self.config.guardrails:
            for pattern in _DATA_DESTRUCTION_PATTERNS:
                if re.search(pattern, command, re.IGNORECASE):
                    return GuardrailResult(
                        allowed=False,
                        guardrail="no_data_destruction",
                        reason=f"Data destruction: matches '{pattern}'",
                    )

        return GuardrailResult(allowed=True)

    def should_auto_resolve(
        self,
        action_name: str,
        success_rate: float,
        occurrences: int,
    ) -> bool:
        """Determine if a pattern-matched fix should be applied autonomously.

        Requires the action to be in the allowed set AND the pattern
        confidence to meet configured thresholds.
        """
        if not self.config.enabled:
            return False
        if not self.is_allowed(action_name):
            return False
        if success_rate < self.config.min_pattern_confidence:
            return False
        if occurrences < self.config.min_pattern_occurrences:
            return False
        return True

    def get_custom_action(self, name: str) -> AdminAction | None:
        """Get a custom action definition by name."""
        return self._custom_actions.get(name)

    def describe(self) -> dict[str, Any]:
        """Describe registry state for diagnostics."""
        return {
            "enabled": self.config.enabled,
            "standard_actions": {
                a: a in self.config.allowed_actions for a in sorted(self.STANDARD_ACTIONS)
            },
            "custom_actions": {a.name: a.description for a in self._custom_actions.values()},
            "guardrails": self.config.guardrails,
            "min_pattern_confidence": self.config.min_pattern_confidence,
            "min_pattern_occurrences": self.config.min_pattern_occurrences,
        }
