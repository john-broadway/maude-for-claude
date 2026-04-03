# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for maude.card — Room capability card MCP resource.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for maude.card — Room capability card MCP resource."""

import json

import pytest

from maude.daemon.card import MAUDE_VERSION, _is_guarded, register_card_resource
from maude.daemon.config import RoomConfig
from maude.testing import FakeMCP


@pytest.fixture
def config():
    return RoomConfig(
        project="test-room",
        service_name="test.service",
        mcp_port=9999,
        ctid=999,
        ip="localhost",
        description="Test room",
        health_loop={"enabled": True},
        room_agent={"enabled": True},
        events={"enabled": True},
        acl={"enabled": False},
        training_loop=None,
    )


@pytest.fixture
def mcp():
    return FakeMCP()


@pytest.fixture
def card_resource(mcp, config):
    register_card_resource(
        mcp, config,
        deps_info={"depends_on": ["postgresql"], "depended_by": ["monitoring"]},
    )
    return mcp.resources.get("room://card")


# ── Registration ─────────────────────────────────────────────────


def test_card_resource_registered(card_resource):
    """register_card_resource registers room://card."""
    assert card_resource is not None
    assert card_resource["uri"] == "room://card"


# ── Card content ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_card_static_fields(card_resource):
    """Card includes static identity fields."""
    fn = card_resource["fn"]
    result = json.loads(await fn())

    assert result["name"] == "test-room"
    assert result["version"] == MAUDE_VERSION
    assert result["ctid"] == 999
    assert result["ip"] == "localhost"
    assert result["mcp_port"] == 9999
    assert result["description"] == "Test room"
    assert "Maude" in result["provider"]


@pytest.mark.asyncio
async def test_card_capabilities(card_resource):
    """Card includes capability flags."""
    fn = card_resource["fn"]
    result = json.loads(await fn())

    caps = result["capabilities"]
    assert caps["health_loop"] is True
    assert caps["room_agent"] is True
    assert caps["events"] is True
    assert caps["memory"] is True
    assert caps["acl"] is False
    assert caps["training_loop"] is False


@pytest.mark.asyncio
async def test_card_dependencies(card_resource):
    """Card includes dependency info when provided."""
    fn = card_resource["fn"]
    result = json.loads(await fn())

    deps = result["dependencies"]
    assert "postgresql" in deps["depends_on"]
    assert "monitoring" in deps["depended_by"]


@pytest.mark.asyncio
async def test_card_tool_list(card_resource):
    """Card includes empty tool list (FakeMCP has no get_tools)."""
    fn = card_resource["fn"]
    result = json.loads(await fn())

    # FakeMCP doesn't implement get_tools() — should gracefully return []
    assert result["tools"] == []
    assert result["tool_count"] == 0


@pytest.mark.asyncio
async def test_card_without_deps(mcp, config):
    """Card works without dependency info."""
    register_card_resource(mcp, config)
    fn = mcp.resources["room://card"]["fn"]
    result = json.loads(await fn())

    assert "dependencies" not in result
    assert result["name"] == "test-room"


# ── Health snapshot ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_card_with_health_loop_ref(mcp, config):
    """Card includes health snapshot when health_loop_ref is available."""

    class _MockHealthLoop:
        last_status = {"healthy": True, "timestamp": "2026-03-14T00:00:00Z"}

    class _Ref:
        _health_loop = _MockHealthLoop()

    register_card_resource(mcp, config, health_loop_ref=_Ref())
    fn = mcp.resources["room://card"]["fn"]
    result = json.loads(await fn())

    assert "health" in result
    assert result["health"]["status"] == "healthy"
    assert result["health"]["last_check"] == "2026-03-14T00:00:00Z"


@pytest.mark.asyncio
async def test_card_without_health_loop(card_resource):
    """Card omits health section when no health loop ref."""
    fn = card_resource["fn"]
    result = json.loads(await fn())

    assert "health" not in result


# ── _is_guarded helper ───────────────────────────────────────────


def test_is_guarded_restart():
    """Tool with 'restart' in name is guarded."""

    class _Tool:
        name = "service_restart"

    assert _is_guarded(_Tool()) is True


def test_is_guarded_status():
    """Tool with 'status' in name is not guarded."""

    class _Tool:
        name = "service_status"

    assert _is_guarded(_Tool()) is False
