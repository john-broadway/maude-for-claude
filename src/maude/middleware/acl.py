# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Role-based access control for Maude MCP tool calls.

Header-based caller identity (X-Maude-Caller) mapped to roles via
config YAML. Tool names matched with fnmatch glob patterns.

No external dependencies — pure Python stdlib.
"""

import logging
from dataclasses import dataclass, field
from fnmatch import fnmatch

logger = logging.getLogger(__name__)


@dataclass
class ACLDecision:
    """Result of an ACL check."""

    allowed: bool
    caller: str
    role: str
    tool: str
    reason: str


@dataclass
class ACLRule:
    """A single ACL rule matching tool patterns to allowed roles."""

    tools: list[str]
    roles: list[str]
    allow: bool = True


@dataclass
class ACLEngine:
    """Evaluate caller access to tools based on role mappings and rules.

    Roles map caller names to role labels. Rules map tool name patterns
    (fnmatch globs) to permitted roles. First matching rule wins.
    """

    roles: dict[str, list[str]] = field(default_factory=dict)
    rules: list[ACLRule] = field(default_factory=list)
    default_allow: bool = True
    enabled: bool = True

    @classmethod
    def from_config(cls, config: dict) -> "ACLEngine":
        """Parse ACL configuration from a YAML dict.

        Expected format::

            acl:
              enabled: true
              default_allow: true
              roles:
                admin: ["claude-code", "coordinator"]
                viewer: ["*"]
              rules:
                - tools: ["service_restart", "kill_switch_*"]
                  roles: ["admin"]
                - tools: ["service_status"]
                  roles: ["admin", "viewer"]
        """
        enabled = config.get("enabled", True)
        default_allow = config.get("default_allow", True)
        roles = config.get("roles", {})
        raw_rules = config.get("rules", [])

        rules: list[ACLRule] = []
        for r in raw_rules:
            rules.append(
                ACLRule(
                    tools=r.get("tools", []),
                    roles=r.get("roles", []),
                    allow=r.get("allow", True),
                )
            )

        return cls(roles=roles, rules=rules, default_allow=default_allow, enabled=enabled)

    def resolve_role(self, caller: str) -> str:
        """Map a caller name to its role. Returns 'unknown' if no match."""
        for role_name, callers in self.roles.items():
            if caller in callers or "*" in callers:
                return role_name
        return "unknown"

    def check(self, caller: str, tool_name: str) -> ACLDecision:
        """Check if caller can invoke tool_name.

        Returns an ACLDecision. If ACL is disabled, always allows.
        First matching rule wins. Unmatched tools fall to default_allow.
        """
        if not self.enabled:
            return ACLDecision(
                allowed=True,
                caller=caller,
                role="",
                tool=tool_name,
                reason="acl disabled",
            )

        role = self.resolve_role(caller)

        for rule in self.rules:
            tool_match = any(fnmatch(tool_name, pattern) for pattern in rule.tools)
            if not tool_match:
                continue
            role_match = role in rule.roles
            if role_match:
                return ACLDecision(
                    allowed=rule.allow,
                    caller=caller,
                    role=role,
                    tool=tool_name,
                    reason=f"rule matched: {rule.tools}",
                )
            else:
                return ACLDecision(
                    allowed=False,
                    caller=caller,
                    role=role,
                    tool=tool_name,
                    reason=f"role '{role}' not in {rule.roles} for {rule.tools}",
                )

        return ACLDecision(
            allowed=self.default_allow,
            caller=caller,
            role=role,
            tool=tool_name,
            reason="default policy",
        )
