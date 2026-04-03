# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for maude.coordination._resources — fleet-level MCP resources.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for maude.coordination._resources — fleet-level MCP resources."""

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.coordination._resources import register_fleet_resources
from maude.testing import FakeMCP


@pytest.fixture
def mcp():
    return FakeMCP()


@pytest.fixture
def mock_deps():
    """Mock DependencyGraph with test data."""
    deps = MagicMock()
    deps.all_rooms = ["site-a/postgresql", "site-a/monitoring", "site-a/my-service"]
    deps.to_dict.return_value = {
        "rooms": {
            "site-a/postgresql": {"depends_on": []},
            "site-a/monitoring": {"depends_on": ["site-a/postgresql"]},
            "site-a/my-service": {"depends_on": ["site-a/postgresql"]},
        }
    }
    deps.depends_on.return_value = ["site-a/postgresql"]
    deps.depended_by.return_value = ["site-a/monitoring"]
    deps.affected_by.return_value = ["site-a/postgresql"]
    deps.model_for.return_value = {"name": "test-model", "base": "Qwen/Qwen3-32B"}
    deps._room_meta = {
        "site-a/postgresql": {"ctid": 1030, "ip": "localhost"},
    }
    return deps


@pytest.fixture
def mock_briefing():
    briefing = MagicMock()
    briefing.room_status = AsyncMock(return_value="postgresql: healthy | monitoring: healthy")
    return briefing


@pytest.fixture
def mock_memory():
    return MagicMock()


@pytest.fixture
def resources(mcp, mock_memory, mock_deps, mock_briefing):
    def get_components():
        return mock_memory, mock_deps, mock_briefing

    register_fleet_resources(mcp, get_components)
    return mcp.resources


# ── Registration ─────────────────────────────────────────────────


def test_register_fleet_resources_count(resources):
    """register_fleet_resources registers exactly 3 resources."""
    assert len(resources) == 3


def test_register_fleet_resources_uris(resources):
    """All 3 expected resource URIs are registered."""
    assert "maude://fleet/dependencies" in resources
    assert "maude://fleet/status" in resources
    assert "maude://fleet/rooms/{room}" in resources


# ── Dependencies resource ────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_dependencies(resources, mock_deps):
    """Fleet dependencies resource returns the full graph."""
    fn = resources["maude://fleet/dependencies"]["fn"]
    result = json.loads(await fn())

    assert "rooms" in result
    mock_deps.to_dict.assert_called_once()


# ── Status resource ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_status(resources, mock_briefing):
    """Fleet status resource calls briefing.room_status()."""
    fn = resources["maude://fleet/status"]["fn"]
    result = await fn()

    assert "postgresql" in result
    mock_briefing.room_status.assert_awaited_once_with(minutes=60)


# ── Room detail resource ─────────────────────────────────────────


@pytest.mark.asyncio
async def test_fleet_room_detail(resources, mock_deps):
    """Fleet room detail resource returns per-room data."""
    fn = resources["maude://fleet/rooms/{room}"]["fn"]
    result = json.loads(await fn("site-a/postgresql"))

    assert result["room"] == "site-a/postgresql"
    assert "depends_on" in result
    assert "depended_by" in result
    assert result["model"] == {"name": "test-model", "base": "Qwen/Qwen3-32B"}
    assert result["metadata"]["ctid"] == 1030
