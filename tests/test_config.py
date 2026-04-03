# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.config — minimal RoomConfig.

Claude (Anthropic) <noreply@anthropic.com>
"""

from pathlib import Path

import pytest

from maude.daemon.config import RoomConfig


def test_room_config_defaults():
    cfg = RoomConfig(project="redis", service_name="redis-server", mcp_port=9211)
    assert cfg.project == "redis"
    assert cfg.ctid == 0
    assert cfg.ip == ""
    assert cfg.executor_mode == "local"
    assert cfg.health_loop is None


def test_room_config_all_fields():
    cfg = RoomConfig(
        project="monitoring",
        service_name="monitoring-server",
        mcp_port=9204,
        ctid=204,
        ip="localhost",
        executor_mode="local",
        description="Grafana dashboard server",
        health_loop={"enabled": True, "interval_seconds": 60},
        room_agent={"enabled": True},
    )
    assert cfg.ctid == 204
    assert cfg.health_loop["interval_seconds"] == 60
    assert cfg.room_agent["enabled"] is True


def test_room_config_from_yaml(tmp_path: Path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: redis\n"
        "service_name: redis-server\n"
        "mcp_port: 9211\n"
        "ctid: 211\n"
        "ip: 'localhost'\n"
        "executor_mode: local\n"
    )
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.project == "redis"
    assert cfg.mcp_port == 9211
    assert cfg.ctid == 211


def test_room_config_from_yaml_port_compat(tmp_path: Path):
    """YAML with 'port' (ServiceConfig style) maps to mcp_port."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: redis\nservice_name: redis-server\nport: 9211\n")
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.mcp_port == 9211


def test_room_config_ignores_unknown_keys(tmp_path: Path):
    """Unknown YAML keys are silently ignored."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: redis\n"
        "service_name: redis-server\n"
        "mcp_port: 9211\n"
        "ssh_alias: redis\n"
        "database: app_data\n"
        "service_port: 6379\n"
    )
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.project == "redis"
    assert not hasattr(cfg, "ssh_alias")
    # raw preserves the full YAML including unknown keys
    assert cfg.raw["ssh_alias"] == "redis"
    assert cfg.raw["service_port"] == 6379


def test_room_config_optional_sections(tmp_path: Path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: monitoring\n"
        "service_name: monitoring-server\n"
        "mcp_port: 9204\n"
        "health_loop:\n"
        "  enabled: true\n"
        "  interval_seconds: 60\n"
        "events:\n"
        "  enabled: true\n"
    )
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.health_loop == {"enabled": True, "interval_seconds": 60}
    assert cfg.events == {"enabled": True}
    assert cfg.redis is None


# --- Validation tests ---


def test_missing_required_field(tmp_path: Path):
    """Missing required field raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("service_name: redis-server\nmcp_port: 9211\n")
    with pytest.raises(TypeError):
        RoomConfig.from_yaml(config_file)


def test_empty_project_raises(tmp_path: Path):
    """Empty project string raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: ''\nservice_name: redis-server\nmcp_port: 9211\n")
    with pytest.raises(ValueError, match="project must be a non-empty string"):
        RoomConfig.from_yaml(config_file)


def test_mcp_port_wrong_type(tmp_path: Path):
    """Non-integer mcp_port raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: redis\nservice_name: redis-server\nmcp_port: not_a_number\n")
    with pytest.raises(ValueError, match="mcp_port must be an integer"):
        RoomConfig.from_yaml(config_file)


def test_mcp_port_out_of_range(tmp_path: Path):
    """Port outside 1-65535 raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: redis\nservice_name: redis-server\nmcp_port: 70000\n")
    with pytest.raises(ValueError, match="mcp_port must be 1-65535"):
        RoomConfig.from_yaml(config_file)


def test_mcp_port_zero(tmp_path: Path):
    """Port 0 raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: redis\nservice_name: redis-server\nmcp_port: 0\n")
    with pytest.raises(ValueError, match="mcp_port must be 1-65535"):
        RoomConfig.from_yaml(config_file)


def test_empty_yaml_raises(tmp_path: Path):
    """Empty YAML file raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("")
    with pytest.raises(ValueError, match="empty or not a YAML mapping"):
        RoomConfig.from_yaml(config_file)


def test_null_yaml_raises(tmp_path: Path):
    """YAML with only 'null' raises ValueError."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("null\n")
    with pytest.raises(ValueError, match="empty or not a YAML mapping"):
        RoomConfig.from_yaml(config_file)


def test_ctid_string_coerced(tmp_path: Path):
    """ctid as string '100' gets coerced to int."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: redis\nservice_name: redis-server\nmcp_port: 9211\nctid: '100'\n"
    )
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.ctid == 100
    assert isinstance(cfg.ctid, int)


def test_multiple_errors_reported(tmp_path: Path):
    """All validation errors are reported together."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text("project: ''\nservice_name: ''\nmcp_port: bad\n")
    with pytest.raises(ValueError, match="project.*service_name.*mcp_port"):
        RoomConfig.from_yaml(config_file)


def test_valid_config_passes_validation(tmp_path: Path):
    """A valid config passes validation without error."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: redis\nservice_name: redis-server\nmcp_port: 9211\nctid: 211\n"
    )
    cfg = RoomConfig.from_yaml(config_file)
    assert cfg.project == "redis"
    assert cfg.mcp_port == 9211
