# Maude Metrics — Prometheus exposition endpoint
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Updated: 2026-04-02
"""Prometheus metrics for Maude rooms.

Provides a ``MaudeMetrics`` class that defines counters/gauges and
a ``make_handler()`` method returning an async Starlette handler for
``/metrics``. Mount via ``FastMCP.custom_route``.

Usage::

    from maude.daemon.metrics import get_metrics

    metrics = get_metrics()
    metrics.tool_calls.labels(tool_name="service_status").inc()
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable

from prometheus_client import CollectorRegistry, Counter, Gauge, generate_latest
from starlette.requests import Request
from starlette.responses import Response

# Module-level singleton — all rooms in one process share metrics.
_instance: MaudeMetrics | None = None


class MaudeMetrics:
    """Prometheus metrics for a Maude room.

    Args:
        registry: Custom registry (for testing). Defaults to a new registry
            to avoid polluting the global default.
    """

    def __init__(self, registry: CollectorRegistry | None = None) -> None:
        self._registry = registry or CollectorRegistry()

        self.tool_calls = Counter(
            "maude_tool_calls_total",
            "Total MCP tool calls",
            ["tool_name"],
            registry=self._registry,
        )

        self.health_checks = Counter(
            "maude_health_checks_total",
            "Total health loop cycles",
            registry=self._registry,
        )

        self.health_check_failures = Counter(
            "maude_health_check_failures_total",
            "Health checks that detected failures",
            registry=self._registry,
        )

        self.memory_writes = Counter(
            "maude_memory_writes_total",
            "Memory store write operations",
            ["memory_type"],
            registry=self._registry,
        )

        self.agent_runs = Counter(
            "maude_agent_runs_total",
            "Room Agent invocations",
            ["trigger"],
            registry=self._registry,
        )

        self.uptime_seconds = Gauge(
            "maude_uptime_seconds",
            "Process uptime in seconds",
            registry=self._registry,
        )

        self.pool_count = Gauge(
            "maude_pool_count",
            "Number of registered database pools",
            registry=self._registry,
        )

    def generate(self) -> bytes:
        """Generate Prometheus exposition format output."""
        return generate_latest(self._registry)

    @property
    def content_type(self) -> str:
        """MIME type for Prometheus exposition."""
        return "text/plain; version=0.0.4; charset=utf-8"

    def make_handler(self) -> Callable[[Request], Awaitable[Response]]:
        """Create an async Starlette handler for /metrics."""
        metrics = self

        async def _handler(request: Request) -> Response:
            # Update pool count gauge on each scrape
            try:
                from maude.db import PoolRegistry

                metrics.pool_count.set(PoolRegistry.pool_count())
            except Exception:
                pass

            return Response(
                content=metrics.generate(),
                media_type=metrics.content_type,
            )

        return _handler


def get_metrics() -> MaudeMetrics:
    """Get or create the module-level metrics singleton."""
    global _instance
    if _instance is None:
        _instance = MaudeMetrics()
    return _instance


def mount_metrics(mcp: object) -> None:
    """Mount /metrics endpoint on a FastMCP server.

    Args:
        mcp: FastMCP instance with ``custom_route`` method.
    """
    metrics = get_metrics()
    handler = metrics.make_handler()

    if hasattr(mcp, "custom_route"):
        mcp.custom_route("/metrics", methods=["GET"], name="prometheus_metrics")(handler)  # type: ignore[union-attr]
