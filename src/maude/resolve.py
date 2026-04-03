# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Infrastructure resolution — Maude knows where everything is.

Resolves infrastructure hosts and credential paths from environment
variables, config files, and conventions. No hardcoded addresses.
"""

import logging
import os
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

# Environment variable prefix for infrastructure hosts
_ENV_PREFIX = "MAUDE_"

# Default infrastructure host keys and their env var names
_INFRA_KEYS = {
    "postgresql": "MAUDE_PG_HOST",
    "qdrant": "MAUDE_QDRANT_HOST",
    "redis": "MAUDE_REDIS_HOST",
    "embedder": "MAUDE_EMBEDDER_URL",
    "coordinator": "MAUDE_COORDINATOR_URL",
    "grafana": "MAUDE_GRAFANA_URL",
    "loki": "MAUDE_LOKI_URL",
    "prometheus": "MAUDE_PROMETHEUS_URL",
}

# Credential search paths, in order of precedence
_CREDENTIAL_PATHS = [
    Path("/etc/maude/credentials"),
    Path.home() / ".credentials",
    Path.home() / ".maude" / "credentials",
]


def resolve_infra_hosts(config_path: Path | None = None) -> dict[str, str]:
    """Resolve infrastructure host addresses.

    Checks in order:
    1. MAUDE_* environment variables
    2. config.yaml infra section (if config_path provided)
    3. Returns only what was found (no defaults — explicit over implicit)

    Args:
        config_path: Optional path to a config.yaml with an 'infra' section.

    Returns:
        Dict of service name to host/URL. Only includes resolved entries.
    """
    hosts: dict[str, str] = {}

    # Layer 1: Environment variables (highest priority)
    for key, env_var in _INFRA_KEYS.items():
        value = os.environ.get(env_var, "")
        if value:
            hosts[key] = value
            logger.debug("Resolved %s from env %s", key, env_var)

    # Layer 2: Config file (lower priority, doesn't override env)
    if config_path and config_path.exists():
        try:
            data = yaml.safe_load(config_path.read_text())
            infra = data.get("infra", {}) if isinstance(data, dict) else {}
            for key, value in infra.items():
                if key not in hosts and isinstance(value, str) and value:
                    hosts[key] = value
                    logger.debug("Resolved %s from config", key)
        except (yaml.YAMLError, OSError) as e:
            logger.warning("Failed to read infra config from %s: %s", config_path, e)

    return hosts


def resolve_credential_path(name: str, project: str | None = None) -> Path | None:
    """Resolve a credential file path by convention.

    Checks in order:
    1. MAUDE_CREDENTIALS_PATH env var (if set, look there first)
    2. /etc/maude/credentials/{name}
    3. ~/.credentials/{name}
    4. ~/.maude/credentials/{name}
    5. If project given: ./{project}/.credentials/{name}

    Args:
        name: Credential filename (e.g. 'pg-password', 'qdrant-api-key').
        project: Optional project name to check project-local credentials.

    Returns:
        Path to the credential file, or None if not found.
    """
    # Check env override first
    env_path = os.environ.get("MAUDE_CREDENTIALS_PATH", "")
    if env_path:
        candidate = Path(env_path) / name
        if candidate.exists():
            return candidate

    # Check standard locations
    for base in _CREDENTIAL_PATHS:
        candidate = base / name
        if candidate.exists():
            return candidate

    # Check project-local
    if project:
        candidate = Path.cwd() / project / ".credentials" / name
        if candidate.exists():
            return candidate

    logger.debug("Credential '%s' not found in any standard location", name)
    return None
