"""Shared runner for standalone Maude MCP servers.

Provides argument parsing, logging setup, and transport configuration
so every room doesn't reinvent the same 30 lines of boilerplate.

If the room's config has health_loop or room_agent enabled, the runner
automatically starts background lifecycle tasks (health monitoring,
LLM-powered diagnostics, event publishing, Redis caching) alongside
the MCP server.

Usage:
    from maude.daemon.runner import run_room
    from maude.daemon.config import RoomConfig

    def create_server(config: RoomConfig) -> FastMCP:
        mcp = FastMCP(name=f"Example Corp {config.project.title()} MCP")
        # register tools...
        return mcp

    if __name__ == "__main__":
        run_room(create_server)

Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
         Claude (Anthropic) <noreply@anthropic.com>
Version: 2.1.0
Updated: 2026-02-13
"""

import argparse
import asyncio
import logging
from collections.abc import Callable
from typing import Any

from fastmcp import FastMCP

from maude.daemon.config import RoomConfig
from maude.healing.health_checks import DomainCheckCallback

logger = logging.getLogger(__name__)


def setup_logging(level: str = "INFO") -> None:
    """Configure structured logging for a Maude room."""
    log_level = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s %(name)-30s %(levelname)-5s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        force=True,
    )


def parse_args(default_config: str = "config.yaml") -> argparse.Namespace:
    """Parse standard Maude room CLI arguments.

    Args:
        default_config: Default config file path.

    Returns:
        Parsed arguments with config, port, transport, and log_level.
    """
    parser = argparse.ArgumentParser(description="Maude MCP Room Server")
    parser.add_argument("--config", default=default_config, help="Path to config YAML")
    parser.add_argument("--port", type=int, default=None, help="Override MCP port")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    parser.add_argument(
        "--transport",
        choices=["streamable-http", "stdio"],
        default="streamable-http",
        help="MCP transport (default: streamable-http)",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging level",
    )
    return parser.parse_args()


def run_room(
    factory: Callable[[RoomConfig], FastMCP | tuple[FastMCP, Any]],
    default_config: str = "config.yaml",
) -> None:
    """Run a standalone Maude room.

    Handles argument parsing, logging, config loading, and MCP server
    startup. The factory function receives a RoomConfig and returns
    either a FastMCP instance or a (FastMCP, extras) tuple.

    Args:
        factory: Function that creates the FastMCP server from config.
        default_config: Default config file path.
    """
    args = parse_args(default_config)
    setup_logging(args.log_level)

    config = RoomConfig.from_yaml(args.config)
    port = args.port or config.mcp_port

    logger.info(
        "Starting %s room (CTID %d, port %d, transport %s)",
        config.project,
        config.ctid,
        port,
        args.transport,
    )

    result = factory(config)
    mcp = result[0] if isinstance(result, tuple) else result

    # Register capability card (basic card — no health loop ref for simple rooms)
    try:
        from maude.daemon.card import register_card_resource

        register_card_resource(mcp, config)
    except Exception:
        logger.debug("Card resource registration skipped for %s", config.project)

    # Mount /metrics endpoint (Prometheus scrape target)
    try:
        from maude.daemon.metrics import mount_metrics

        mount_metrics(mcp)
        logger.info("Prometheus /metrics mounted for %s", config.project)
    except Exception:
        logger.debug("Metrics endpoint skipped for %s", config.project)

    # If health loop or room agent is configured, run with full lifecycle
    # (background health monitoring, LLM agent, event publishing, etc.)
    has_health_loop = config.health_loop and config.health_loop.get("enabled")
    has_room_agent = config.room_agent and config.room_agent.get("enabled")

    if has_health_loop or has_room_agent:
        from maude.healing.lifecycle import run_with_lifecycle

        domain_checks: DomainCheckCallback | None = getattr(
            mcp,
            "_maude_domain_checks",
            None,
        )
        extra_startup = getattr(mcp, "_maude_extra_startup", None)
        extra_shutdown = getattr(mcp, "_maude_extra_shutdown", None)

        asyncio.run(
            run_with_lifecycle(
                mcp,
                config,
                transport=args.transport,
                host=args.host,
                port=port,
                domain_checks=domain_checks,
                extra_startup=extra_startup,
                extra_shutdown=extra_shutdown,
            )
        )
    elif args.transport == "stdio":
        mcp.run(transport="stdio")
    else:
        mcp.run(transport="streamable-http", host=args.host, port=port, json_response=True)
