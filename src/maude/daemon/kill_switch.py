# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Kill switch for per-project MCP servers.

When the kill switch is active, all write/mutating tools are blocked.
Read-only tools continue to work.

Flag file: /var/lib/maude/<project>/readonly
"""

import logging
from pathlib import Path

logger = logging.getLogger(__name__)

KILL_SWITCH_DIR = Path("/var/lib/maude/")


class KillSwitch:
    """Check and manage the read-only kill switch for a project.

    Args:
        project: Project identifier (e.g., "my-service").
    """

    def __init__(self, project: str) -> None:
        self.project = project
        self.flag_path = KILL_SWITCH_DIR / project / "readonly"

    @property
    def active(self) -> bool:
        """Check if the kill switch is currently active."""
        return self.flag_path.exists()

    def activate(self, reason: str = "") -> None:
        """Activate the kill switch (block all writes)."""
        self.flag_path.parent.mkdir(parents=True, exist_ok=True)
        self.flag_path.write_text(reason or "Activated manually")
        logger.warning("Kill switch ACTIVATED for %s: %s", self.project, reason)

    def deactivate(self) -> None:
        """Deactivate the kill switch (allow writes)."""
        self.flag_path.unlink(missing_ok=True)
        logger.info("Kill switch DEACTIVATED for %s", self.project)

    def check_or_raise(self) -> None:
        """Raise if kill switch is active. Used by guard decorators."""
        try:
            reason = self.flag_path.read_text().strip()
        except FileNotFoundError:
            return
        raise PermissionError(
            f"Kill switch active for {self.project}: {reason}. "
            f"Nobody's writing anything until I say so."
        )

    def status(self) -> dict[str, str | bool]:
        """Return kill switch status as a dict."""
        try:
            reason = self.flag_path.read_text().strip()
            active = True
        except FileNotFoundError:
            reason = ""
            active = False
        description = (
            f"Locked down. Reason: {reason}. I'll let you know when it's safe to write again."
            if active
            else "All clear, you can write. But I'm watching."
        )
        return {
            "project": self.project,
            "active": active,
            "reason": reason,
            "description": description,
            "flag_path": str(self.flag_path),
        }
