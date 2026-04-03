# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Room configuration for Maude MCP servers.

RoomConfig holds only the fields needed to compose a room via
register_ops_tools() and the runner.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

_logger = logging.getLogger(__name__)


@dataclass
class RoomConfig:
    """Minimal configuration for a standalone Maude room.

    Only the fields every room needs. Optional sections (health_loop,
    room_agent, events, redis) are loaded as raw dicts — the room
    decides what to do with them.
    """

    project: str
    service_name: str
    mcp_port: int = 9900
    ctid: int = 0
    ip: str = ""
    executor_mode: str = "local"
    description: str = ""
    database: str = ""

    # Optional sections — room reads what it needs
    health_loop: dict[str, Any] | None = field(default=None, repr=False)
    room_agent: dict[str, Any] | None = field(default=None, repr=False)
    events: dict[str, Any] | None = field(default=None, repr=False)
    redis: dict[str, Any] | None = field(default=None, repr=False)
    acl: dict[str, Any] | None = field(default=None, repr=False)
    training_loop: dict[str, Any] | None = field(default=None, repr=False)

    # Full YAML dict — rooms can read custom sections not in dataclass fields
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_yaml(cls, path: str | Path) -> "RoomConfig":
        """Load config from YAML file.

        Ignores unknown keys so room-specific YAML can carry extra
        fields without breaking the loader.  Validates required fields
        and types after loading.
        """
        data = yaml.safe_load(Path(path).read_text())
        if not isinstance(data, dict):
            raise ValueError("config file is empty or not a YAML mapping")
        known = set(cls.__dataclass_fields__)
        # Map 'port' → 'mcp_port' for backward compat with ServiceConfig YAMLs
        if "port" in data and "mcp_port" not in data:
            data["mcp_port"] = data.pop("port")
        # Coerce ctid from string to int before construction
        if "ctid" in data and isinstance(data["ctid"], str):
            try:
                data["ctid"] = int(data["ctid"])
            except (ValueError, TypeError):
                pass  # will be caught by _validate
        filtered = {k: v for k, v in data.items() if k in known}
        cfg = cls(**filtered)
        cfg.raw = data
        cfg._validate()
        return cfg

    def _validate(self) -> None:
        """Check required fields and types. Collects all errors."""
        errors: list[str] = []
        # Required non-empty strings
        if not self.project or not isinstance(self.project, str):
            errors.append("project must be a non-empty string")
        if not self.service_name or not isinstance(self.service_name, str):
            errors.append("service_name must be a non-empty string")
        # mcp_port: must be int in valid range
        if not isinstance(self.mcp_port, int) or isinstance(self.mcp_port, bool):
            errors.append(f"mcp_port must be an integer, got {type(self.mcp_port).__name__}")
        elif not 1 <= self.mcp_port <= 65535:
            errors.append(f"mcp_port must be 1-65535, got {self.mcp_port}")
        # ctid: must be int
        if not isinstance(self.ctid, int) or isinstance(self.ctid, bool):
            errors.append(f"ctid must be an integer, got {type(self.ctid).__name__}")
        if errors:
            raise ValueError("config validation failed: " + "; ".join(errors))

        # Soft warnings for suspect identity values (don't block startup)
        if isinstance(self.ctid, int) and self.ctid and self.ctid < 100:
            _logger.warning(
                "config ctid %d seems low (typical CTIDs are 100+) — "
                "check config-local.yaml matches the source config.yaml",
                self.ctid,
            )
