# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Starter tests for {{PROJECT}} domain health tool."""

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from {{PROJECT}}_mcp.tools.health import register_health_tools


@pytest.fixture
def mcp_with_health(mock_ssh, mock_audit):
    """Register health tools on a mock MCP and return the tool function."""
    mcp = MagicMock()
    registered_tools: dict = {}

    def capture_tool():
        def decorator(fn):
            registered_tools[fn.__name__] = fn
            return fn
        return decorator

    mcp.tool = capture_tool
    register_health_tools(mcp, mock_ssh, mock_audit)
    return registered_tools


@pytest.mark.asyncio
async def test_health_returns_valid_json(mcp_with_health):
    """The domain health tool should return parseable JSON."""
    tool_fn = mcp_with_health["{{PROJECT}}_health"]
    result = await tool_fn()
    data = json.loads(result)
    assert "status" in data
