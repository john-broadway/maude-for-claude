# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for maude.resources — per-room MCP resources.
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for maude.resources — per-room MCP resources."""

import json

import pytest

from maude.daemon.config import RoomConfig
from maude.daemon.resources import register_ops_resources
from maude.testing import FakeExecutor, FakeMCP, FakeSSHResult


@pytest.fixture
def executor():
    return FakeExecutor(responses={
        "systemctl is-active": FakeSSHResult(stdout="active"),
        "free -m": FakeSSHResult(stdout="45"),
        "df -h /": FakeSSHResult(stdout="32"),
        "journalctl": FakeSSHResult(stdout="2"),
    })


@pytest.fixture
def mcp():
    return FakeMCP()


@pytest.fixture
def config():
    return RoomConfig(
        project="test-room",
        service_name="test.service",
        mcp_port=9999,
        ctid=999,
        ip="localhost",
        description="Test room for unit tests",
        health_loop={"enabled": True},
        room_agent={"enabled": False},
        events={"enabled": True},
        acl=None,
        training_loop=None,
    )


@pytest.fixture
def resources(mcp, executor, config):
    register_ops_resources(
        mcp, executor, "test.service", "test-room",
        ctid=999, ip="localhost", mcp_port=9999, config=config,
    )
    return mcp.resources


# ── Registration ─────────────────────────────────────────────────


def test_register_ops_resources_count(resources):
    """register_ops_resources registers exactly 2 resources."""
    assert len(resources) == 2


def test_register_ops_resources_uris(resources):
    """Both expected resource URIs are registered."""
    assert "maude://test-room/status" in resources
    assert "maude://test-room/config" in resources


# ── Status resource ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_status_resource_returns_health(resources, executor):
    """Status resource returns JSON with health data."""
    fn = resources["maude://test-room/status"]["fn"]
    result = json.loads(await fn())

    assert result["project"] == "test-room"
    assert result["ctid"] == 999
    assert result["ip"] == "localhost"
    assert result["service_active"] is True
    assert result["healthy"] is True
    assert result["status"] == "healthy"


@pytest.mark.asyncio
async def test_status_resource_unhealthy(mcp, config):
    """Status resource reports unhealthy when service is inactive."""
    executor = FakeExecutor(responses={
        "systemctl is-active": FakeSSHResult(stdout="inactive"),
        "free -m": FakeSSHResult(stdout="45"),
        "df -h /": FakeSSHResult(stdout="32"),
        "journalctl": FakeSSHResult(stdout="0"),
    })
    register_ops_resources(
        mcp, executor, "test.service", "test-room",
        ctid=999, ip="localhost", mcp_port=9999, config=config,
    )
    fn = mcp.resources["maude://test-room/status"]["fn"]
    result = json.loads(await fn())
    assert result["healthy"] is False
    assert result["service_active"] is False


# ── Config resource ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_config_resource_returns_static(resources):
    """Config resource returns static room configuration."""
    fn = resources["maude://test-room/config"]["fn"]
    result = json.loads(await fn())

    assert result["project"] == "test-room"
    assert result["service_name"] == "test.service"
    assert result["ctid"] == 999
    assert result["ip"] == "localhost"
    assert result["mcp_port"] == 9999


@pytest.mark.asyncio
async def test_config_resource_capabilities(resources):
    """Config resource includes capability flags from RoomConfig."""
    fn = resources["maude://test-room/config"]["fn"]
    result = json.loads(await fn())

    caps = result["capabilities"]
    assert caps["health_loop"] is True
    assert caps["room_agent"] is False
    assert caps["events"] is True
    assert caps["memory"] is True
    assert caps["acl"] is False
    assert caps["training_loop"] is False


@pytest.mark.asyncio
async def test_config_resource_without_config(mcp, executor):
    """Config resource works without a RoomConfig object."""
    register_ops_resources(
        mcp, executor, "test.service", "basic",
        ctid=100, ip="localhost", mcp_port=9000,
    )
    fn = mcp.resources["maude://basic/config"]["fn"]
    result = json.loads(await fn())

    assert result["project"] == "basic"
    assert "capabilities" not in result
