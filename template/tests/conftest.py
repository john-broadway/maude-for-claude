# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Shared test fixtures for {{PROJECT}} MCP."""

from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.audit import AuditLogger
from maude.executor import SSHExecutor
from maude.testing import FakeSSHResult


@pytest.fixture
def mock_ssh() -> AsyncMock:
    """Mock SSHExecutor that returns empty stdout by default."""
    ssh = AsyncMock(spec=SSHExecutor)
    ssh.run.return_value = FakeSSHResult(stdout="", stderr="", exit_code=0)
    return ssh


@pytest.fixture
def mock_audit() -> MagicMock:
    """Mock AuditLogger with async log_tool_call."""
    audit = MagicMock(spec=AuditLogger)
    audit.log_tool_call = AsyncMock()
    return audit
