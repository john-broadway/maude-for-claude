"""Shared test fixtures for Room Agent component tests."""

from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.db.pool import PoolRegistry


@pytest.fixture(autouse=True)
def _clean_pool_registry():
    """Reset PoolRegistry between tests so shared-pool injection doesn't leak."""
    PoolRegistry._pools.clear()
    yield
    PoolRegistry._pools.clear()


def pytest_collection_modifyitems(config, items):
    """Auto-mark tests in tests/integration/ as integration tests."""
    for item in items:
        if "/integration/" in str(item.fspath):
            item.add_marker(pytest.mark.integration)


@pytest.fixture
def mock_audit() -> AsyncMock:
    """Mock AuditLogger that records calls."""
    audit = AsyncMock()
    audit.log_tool_call = AsyncMock()
    return audit


@pytest.fixture
def mock_executor() -> AsyncMock:
    """Mock SSH executor that returns configurable results."""
    executor = AsyncMock()

    result = MagicMock()
    result.stdout = "active\n"
    result.ok = True
    executor.run = AsyncMock(return_value=result)

    return executor
