# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.runtime.lifecycle — setup helpers and middleware wiring."""

import asyncio
from unittest.mock import MagicMock, patch

from maude.daemon.config import RoomConfig
from maude.healing.lifecycle import (
    _setup_event_publisher,
    _setup_health_loop,
    _setup_memory_store,
    _setup_redis,
    _start_room_agent_schedule,
    _wire_middleware,
)


def _make_config(**overrides) -> RoomConfig:
    """Create a minimal RoomConfig for testing."""
    defaults = {
        "project": "testroom",
        "service_name": "test-service",
        "mcp_port": 9999,
    }
    defaults.update(overrides)
    return RoomConfig(**defaults)


# ── _wire_middleware ─────────────────────────────────────────────────


def test_wire_middleware_adds_middleware():
    mcp = MagicMock()
    config = _make_config()
    audit = MagicMock()

    with (
        patch("maude.middleware.concierge.ConciergeServices"),
        patch("maude.middleware.acl.ACLEngine", create=True),
    ):
        _wire_middleware(mcp, config, audit)

    mcp.add_middleware.assert_called_once()


def test_wire_middleware_creates_acl_when_enabled():
    mcp = MagicMock()
    config = _make_config(acl={"enabled": True, "roles": {}, "rules": []})
    audit = MagicMock()

    with (
        patch("maude.middleware.concierge.ConciergeServices"),
        patch("maude.middleware.acl.ACLEngine") as mock_acl_cls,
    ):
        _wire_middleware(mcp, config, audit)

    mock_acl_cls.from_config.assert_called_once_with(config.acl)
    mcp.add_middleware.assert_called_once()


def test_wire_middleware_no_acl_when_disabled():
    mcp = MagicMock()
    config = _make_config(acl={"enabled": False})
    audit = MagicMock()

    with (
        patch("maude.middleware.concierge.ConciergeServices"),
        patch("maude.middleware.acl.ACLEngine") as mock_acl_cls,
    ):
        _wire_middleware(mcp, config, audit)

    mock_acl_cls.from_config.assert_not_called()


def test_wire_middleware_no_acl_when_missing():
    mcp = MagicMock()
    config = _make_config()
    audit = MagicMock()

    with (
        patch("maude.middleware.concierge.ConciergeServices"),
        patch("maude.middleware.acl.ACLEngine") as mock_acl_cls,
    ):
        _wire_middleware(mcp, config, audit)

    mock_acl_cls.from_config.assert_not_called()


def test_wire_middleware_handles_import_failure():
    mcp = MagicMock()
    config = _make_config()
    audit = MagicMock()

    with patch.dict("sys.modules", {"maude.middleware.concierge": None}):
        # Should not raise — logs warning instead
        _wire_middleware(mcp, config, audit)

    mcp.add_middleware.assert_not_called()


# ── _setup_memory_store ──────────────────────────────────────────────


def test_setup_memory_store_returns_instance():
    config = _make_config()
    mock_store = MagicMock()

    with patch("maude.memory.store.MemoryStore", return_value=mock_store):
        result = _setup_memory_store(config)

    assert result is mock_store


def test_setup_memory_store_returns_none_on_failure():
    config = _make_config()

    with patch(
        "maude.memory.store.MemoryStore",
        side_effect=ImportError("qdrant not installed"),
    ):
        result = _setup_memory_store(config)

    assert result is None


# ── _setup_event_publisher ───────────────────────────────────────────


def test_setup_event_publisher_returns_none_when_no_events():
    config = _make_config()
    assert _setup_event_publisher(config) is None


def test_setup_event_publisher_returns_none_when_disabled():
    config = _make_config(events={"enabled": False})
    assert _setup_event_publisher(config) is None


def test_setup_event_publisher_returns_publisher_when_enabled():
    config = _make_config(events={"enabled": True, "db_host": "localhost", "database": "agent"})
    mock_pub = MagicMock()

    with patch("maude.infra.events.EventPublisher", return_value=mock_pub):
        result = _setup_event_publisher(config)

    assert result is mock_pub


def test_setup_event_publisher_redis_backend():
    config = _make_config(
        events={"enabled": True, "backend": "redis", "db_host": "localhost"},
        redis={"enabled": True, "host": "localhost", "port": 6379, "db": 0},
    )
    mock_pg = MagicMock()
    mock_redis_pub = MagicMock()

    with (
        patch("maude.infra.events.EventPublisher", return_value=mock_pg),
        patch("maude.infra.events.RedisEventPublisher", return_value=mock_redis_pub),
        patch("maude.infra.redis_client.MaudeRedis"),
        patch("maude.daemon.common.resolve_redis_host", return_value="localhost"),
    ):
        result = _setup_event_publisher(config)

    assert result is mock_redis_pub


def test_setup_event_publisher_returns_none_on_failure():
    config = _make_config(events={"enabled": True})

    with patch(
        "maude.infra.events.EventPublisher",
        side_effect=Exception("connection failed"),
    ):
        result = _setup_event_publisher(config)

    assert result is None


# ── _setup_redis ─────────────────────────────────────────────────────


def test_setup_redis_returns_none_when_no_config():
    config = _make_config()
    assert _setup_redis(config) is None


def test_setup_redis_returns_none_when_disabled():
    config = _make_config(redis={"enabled": False})
    assert _setup_redis(config) is None


def test_setup_redis_returns_client_when_enabled():
    config = _make_config(redis={"enabled": True, "host": "localhost", "port": 6379, "db": 0})
    mock_redis = MagicMock()

    with patch("maude.infra.redis_client.MaudeRedis", return_value=mock_redis):
        result = _setup_redis(config)

    assert result is mock_redis


def test_setup_redis_resolves_host_from_secrets():
    config = _make_config(redis={"enabled": True, "port": 6379, "db": 0})
    mock_redis = MagicMock()

    with (
        patch("maude.infra.redis_client.MaudeRedis", return_value=mock_redis) as cls,
        patch("maude.daemon.common.resolve_redis_host", return_value="localhost"),
    ):
        result = _setup_redis(config)

    assert result is mock_redis
    assert cls.call_args.kwargs["host"] == "localhost"


def test_setup_redis_returns_none_on_import_error():
    config = _make_config(redis={"enabled": True, "host": "localhost"})

    with patch(
        "maude.infra.redis_client.MaudeRedis",
        side_effect=ImportError("redis not installed"),
    ):
        result = _setup_redis(config)

    assert result is None


# ── _setup_health_loop ───────────────────────────────────────────────


def test_setup_health_loop_returns_none_when_no_config():
    config = _make_config()
    assert _setup_health_loop(config, MagicMock(), MagicMock(), None, None) is None


def test_setup_health_loop_returns_none_when_disabled():
    config = _make_config(health_loop={"enabled": False})
    assert _setup_health_loop(config, MagicMock(), MagicMock(), None, None) is None


def test_setup_health_loop_returns_loop_when_enabled():
    config = _make_config(health_loop={"enabled": True, "interval_seconds": 60})
    mock_loop = MagicMock()

    with patch("maude.healing.health_loop.HealthLoop", return_value=mock_loop):
        result = _setup_health_loop(config, MagicMock(), MagicMock(), None, None)

    assert result is mock_loop


def test_setup_health_loop_returns_none_on_failure():
    config = _make_config(health_loop={"enabled": True})

    with patch(
        "maude.healing.health_loop.HealthLoop",
        side_effect=Exception("init failed"),
    ):
        result = _setup_health_loop(config, MagicMock(), MagicMock(), None, None)

    assert result is None


# ── _start_room_agent_schedule ───────────────────────────────────────


async def test_schedule_returns_none_when_no_agent():
    tools_ready = asyncio.Event()
    result = _start_room_agent_schedule(None, _make_config(), tools_ready)
    assert result is None


async def test_schedule_returns_none_when_no_room_agent_config():
    config = _make_config()
    mock_agent = MagicMock()
    tools_ready = asyncio.Event()

    result = _start_room_agent_schedule(mock_agent, config, tools_ready)
    assert result is None


async def test_schedule_returns_none_when_no_schedule_triggers():
    config = _make_config(
        room_agent={
            "enabled": True,
            "triggers": [{"type": "escalation"}],
        }
    )
    mock_agent = MagicMock()
    tools_ready = asyncio.Event()

    result = _start_room_agent_schedule(mock_agent, config, tools_ready)
    assert result is None


async def test_schedule_returns_task_when_schedule_trigger_exists():
    config = _make_config(
        room_agent={
            "enabled": True,
            "triggers": [{"type": "schedule", "interval_seconds": 3600}],
        }
    )
    mock_agent = MagicMock()
    tools_ready = asyncio.Event()

    task = _start_room_agent_schedule(mock_agent, config, tools_ready)

    assert task is not None
    assert isinstance(task, asyncio.Task)
    assert "room-agent-schedule" in task.get_name()

    # Clean up the background task
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


async def test_schedule_accepts_health_loop_parameter():
    """health_loop parameter is accepted and used for gating."""
    config = _make_config(
        room_agent={
            "enabled": True,
            "triggers": [{"type": "schedule", "interval_seconds": 3600}],
        }
    )
    mock_agent = MagicMock()
    tools_ready = asyncio.Event()
    mock_health_loop = MagicMock()
    mock_health_loop.has_recent_issues = MagicMock(return_value=False)

    task = _start_room_agent_schedule(
        mock_agent,
        config,
        tools_ready,
        health_loop=mock_health_loop,
    )
    assert task is not None
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


async def test_schedule_deep_check_every_config():
    """deep_check_every can be configured via trigger config."""
    config = _make_config(
        room_agent={
            "enabled": True,
            "triggers": [
                {
                    "type": "schedule",
                    "interval_seconds": 3600,
                    "deep_check_every": 4,
                }
            ],
        }
    )
    mock_agent = MagicMock()
    tools_ready = asyncio.Event()

    task = _start_room_agent_schedule(mock_agent, config, tools_ready)
    assert task is not None
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
