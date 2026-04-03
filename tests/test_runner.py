# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.runner — shared room runner.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import logging
from unittest.mock import MagicMock, patch

from maude.daemon.config import RoomConfig
from maude.daemon.runner import parse_args, run_room, setup_logging


def test_setup_logging_sets_level():
    setup_logging("DEBUG")
    assert logging.getLogger().level == logging.DEBUG
    # Reset
    setup_logging("WARNING")


def test_parse_args_defaults():
    with patch("sys.argv", ["prog"]):
        args = parse_args()
    assert args.config == "config.yaml"
    assert args.port is None
    assert args.transport == "streamable-http"
    assert args.log_level == "INFO"


def test_parse_args_custom():
    with patch("sys.argv", ["prog", "--config", "my.yaml", "--port", "9999",
                             "--transport", "stdio", "--log-level", "DEBUG"]):
        args = parse_args()
    assert args.config == "my.yaml"
    assert args.port == 9999
    assert args.transport == "stdio"
    assert args.log_level == "DEBUG"


def test_run_room_streamable_http(tmp_path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: test\n"
        "service_name: test.service\n"
        "mcp_port: 9999\n"
        "ctid: 999\n"
    )

    mock_mcp = MagicMock()

    def factory(config: RoomConfig) -> MagicMock:
        assert config.project == "test"
        assert config.mcp_port == 9999
        return mock_mcp

    with patch("sys.argv", ["prog", "--config", str(config_file)]):
        run_room(factory)

    mock_mcp.run.assert_called_once_with(
        transport="streamable-http", host="0.0.0.0", port=9999, json_response=True,
    )


def test_run_room_stdio(tmp_path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: test\n"
        "service_name: test.service\n"
        "mcp_port: 9999\n"
    )

    mock_mcp = MagicMock()

    with patch("sys.argv", ["prog", "--config", str(config_file),
                             "--transport", "stdio"]):
        run_room(lambda cfg: mock_mcp)

    mock_mcp.run.assert_called_once_with(transport="stdio")


def test_run_room_port_override(tmp_path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: test\n"
        "service_name: test.service\n"
        "mcp_port: 9999\n"
    )

    mock_mcp = MagicMock()

    with patch("sys.argv", ["prog", "--config", str(config_file),
                             "--port", "8888"]):
        run_room(lambda cfg: mock_mcp)

    mock_mcp.run.assert_called_once_with(
        transport="streamable-http", host="0.0.0.0", port=8888, json_response=True,
    )


def test_run_room_tuple_return(tmp_path):
    """Factory returning (mcp, extras) tuple extracts mcp correctly."""
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "project: test\n"
        "service_name: test.service\n"
        "mcp_port: 9999\n"
    )

    mock_mcp = MagicMock()
    extras = {"health_loop": MagicMock()}

    with patch("sys.argv", ["prog", "--config", str(config_file)]):
        run_room(lambda cfg: (mock_mcp, extras))

    mock_mcp.run.assert_called_once()
