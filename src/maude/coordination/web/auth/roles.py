# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Dashboard roles and user identity."""

from __future__ import annotations

import enum
from dataclasses import dataclass


class DashboardRole(enum.IntEnum):
    """Role hierarchy — higher value = more permissions."""

    VIEWER = 1
    OPERATOR = 2
    ADMIN = 3


@dataclass(frozen=True)
class DashboardUser:
    """Authenticated dashboard user."""

    name: str
    email: str
    role: DashboardRole
    session_id: str = ""

    @property
    def is_admin(self) -> bool:
        return self.role >= DashboardRole.ADMIN

    @property
    def is_operator(self) -> bool:
        return self.role >= DashboardRole.OPERATOR

    def has_role(self, minimum: DashboardRole) -> bool:
        """Check if user meets minimum role requirement."""
        return self.role >= minimum


# Anonymous user for unauthenticated access (dev mode / auth disabled).
ANONYMOUS_USER = DashboardUser(
    name="Anonymous",
    email="",
    role=DashboardRole.ADMIN,  # Full access when auth is disabled.
)
