# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Health check types, config, and constants.

Extracted from health_loop.py to share with ops.py and other consumers
without pulling in the full HealthLoop machinery.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import os
import re as _re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Kill switch flag directory (same as kill_switch.py)
KILL_SWITCH_DIR = Path("/var/lib/maude/")

# Health thresholds — shared with ops.py service_health and service_trends
MEMORY_THRESHOLD_PCT = 90  # Memory usage above this triggers restart
DISK_THRESHOLD_PCT = 80  # Disk usage above this triggers escalation (restart won't help)
SWAP_THRESHOLD_PCT = 80  # Swap usage above this triggers escalation (restart won't help)
ERROR_THRESHOLD_COUNT = 10  # Errors in 5min above this triggers restart

# Type for domain check callbacks: async () -> dict[str, Any]
DomainCheckCallback = Callable[[], Awaitable[dict[str, Any]]]

# Type for escalation callbacks: async (trigger, context) -> None
EscalationCallback = Callable[[str, dict[str, Any]], Awaitable[None]]

# Type for optional memory callbacks
EmbedCallback = Callable[..., Awaitable[None]]
PastFixCallback = Callable[[str, str], Awaitable[str | None]]


@dataclass
class HealthStatus:
    """Result of a single health check cycle."""

    service_active: bool = False
    memory_percent: int = 0
    disk_percent: int = 0
    swap_percent: int = 0
    recent_errors: int = 0
    endpoint_healthy: bool | None = None  # None = not configured
    endpoint_detail: str = ""
    domain_signals: dict[str, Any] = field(default_factory=dict)
    kill_switch_active: bool = False
    credentials_healthy: bool = True
    credential_failures: list[str] = field(default_factory=list)
    healthy: bool = True
    action: str = "none"
    reason: str = ""


@dataclass
class CredentialProbe:
    """A credential health probe — tests one service credential."""

    name: str
    probe_type: str  # "http", "pg", "vllm"
    url: str = ""
    expect_status: int = 200
    section: str = ""
    timeout: int = 5

    def resolve_url(self) -> str:
        """Substitute ${ENV_VAR} patterns in URL with environment values."""

        def _sub(m: _re.Match[str]) -> str:
            return os.environ.get(m.group(1), m.group(0))

        return _re.sub(r"\$\{(\w+)\}", _sub, self.url)


@dataclass
class HealthLoopConfig:
    """Parsed health loop configuration."""

    enabled: bool = False
    interval_seconds: int = 300
    max_restart_attempts: int = 3
    cooldown_seconds: int = 600
    heartbeat_url: str = ""
    health_endpoint: str = ""
    health_endpoint_timeout: int = 10
    restart_command: str = ""  # Override for non-systemd services (e.g. Docker Compose)
    predictive: dict[str, Any] = field(default_factory=dict)
    credential_probes: list[CredentialProbe] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict | None) -> "HealthLoopConfig":
        if not data:
            return cls()
        probes_raw = data.get("credential_probes", [])
        probes = [
            CredentialProbe(
                name=p["name"],
                probe_type=p["type"],
                url=p.get("url", ""),
                expect_status=p.get("expect_status", 200),
                section=p.get("section", ""),
                timeout=p.get("timeout", 5),
            )
            for p in probes_raw
        ]
        return cls(
            enabled=data.get("enabled", False),
            interval_seconds=data.get("interval_seconds", 300),
            max_restart_attempts=data.get("max_restart_attempts", 3),
            cooldown_seconds=data.get("cooldown_seconds", 600),
            heartbeat_url=data.get("heartbeat_url", ""),
            health_endpoint=data.get("health_endpoint", ""),
            health_endpoint_timeout=data.get("health_endpoint_timeout", 10),
            restart_command=data.get("restart_command", ""),
            predictive=data.get("predictive", {}),
            credential_probes=probes,
        )


def status_to_context(status: HealthStatus) -> dict[str, Any]:
    """Convert HealthStatus to a serializable dict for escalation context."""
    return {
        "service_active": status.service_active,
        "memory_percent": status.memory_percent,
        "disk_percent": status.disk_percent,
        "swap_percent": status.swap_percent,
        "recent_errors": status.recent_errors,
        "endpoint_healthy": status.endpoint_healthy,
        "endpoint_detail": status.endpoint_detail,
        "domain_signals": status.domain_signals,
        "kill_switch_active": status.kill_switch_active,
        "credentials_healthy": status.credentials_healthy,
        "credential_failures": status.credential_failures,
        "healthy": status.healthy,
        "action": status.action,
        "reason": status.reason,
    }


# Backward-compat alias for code that uses the underscore-prefixed name.
_status_to_context = status_to_context
