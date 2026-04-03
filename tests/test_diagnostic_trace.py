# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for DiagnosticTracer — pipeline and dependency chain tracing."""

from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.coordination.diagnostic_trace import DiagnosticTracer, TraceHop, TraceResult


def _make_graph() -> MagicMock:
    """Mock DependencyGraph matching dependencies.yaml topology."""
    graph = MagicMock()

    deps_map = {
        "collector": [],
        "postgresql": [],
        "influxdb": [],
        "prometheus": [],
        "loki": [],
        "monitoring": ["postgresql", "prometheus", "loki"],
        "dashboard": ["postgresql", "collector"],
        "my-service": ["postgresql", "influxdb"],
        "panel": ["postgresql", "my-service"],
    }

    graph.depends_on = lambda room: list(deps_map.get(room, []))
    graph.all_rooms = sorted(deps_map.keys())

    return graph


@pytest.fixture
def graph() -> MagicMock:
    return _make_graph()


@pytest.fixture
def healthy_checker() -> AsyncMock:
    """Health checker that always returns healthy."""
    checker = AsyncMock()
    checker.return_value = {"status": "healthy", "detail": "OK"}
    return checker


# ── trace_data_pipeline ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_pipeline_all_healthy(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("plc_to_monitoring")

    assert result.name == "plc_to_monitoring"
    assert result.healthy is True
    assert result.broken_at is None
    assert len(result.hops) == 3
    assert result.hops[0].room == "collector"
    assert result.hops[1].room == "postgresql"
    assert result.hops[2].room == "monitoring"
    assert all(h.status == "healthy" for h in result.hops)


@pytest.mark.asyncio
async def test_pipeline_broken_at_middle(graph: MagicMock):
    async def checker(room: str) -> dict:
        if room == "postgresql":
            return {"status": "unhealthy", "detail": "disk full"}
        return {"status": "healthy", "detail": "OK"}

    tracer = DiagnosticTracer(graph, health_checker=checker)
    result = await tracer.trace_data_pipeline("plc_to_monitoring")

    assert result.healthy is False
    assert result.broken_at == "postgresql"
    assert result.hops[1].status == "unhealthy"
    assert result.hops[1].detail == "disk full"


@pytest.mark.asyncio
async def test_pipeline_custom_rooms(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("my-service,postgresql")

    assert result.name == "custom:my-service,postgresql"
    assert len(result.hops) == 2


@pytest.mark.asyncio
async def test_pipeline_unknown_room(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("nonexistent,postgresql")

    assert result.healthy is False
    assert result.hops[0].room == "nonexistent"
    assert result.hops[0].status == "unreachable"


@pytest.mark.asyncio
async def test_pipeline_empty(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("")

    assert result.hops == []
    assert result.healthy is True


@pytest.mark.asyncio
async def test_pipeline_no_health_checker(graph: MagicMock):
    tracer = DiagnosticTracer(graph, health_checker=None)
    result = await tracer.trace_data_pipeline("plc_to_monitoring")

    assert all(h.status == "skipped" for h in result.hops)


@pytest.mark.asyncio
async def test_pipeline_health_checker_exception(graph: MagicMock):
    checker = AsyncMock(side_effect=RuntimeError("connection refused"))
    tracer = DiagnosticTracer(graph, health_checker=checker)
    result = await tracer.trace_data_pipeline("metrics")

    assert result.healthy is False
    assert all(h.status == "unreachable" for h in result.hops)


@pytest.mark.asyncio
async def test_pipeline_plc_to_dashboard(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("plc_to_dashboard")

    assert result.name == "plc_to_dashboard"
    assert [h.room for h in result.hops] == ["collector", "postgresql", "dashboard"]


@pytest.mark.asyncio
async def test_pipeline_logs(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_data_pipeline("logs")

    assert result.name == "logs"
    assert [h.room for h in result.hops] == ["loki", "monitoring"]


# ── trace_dependency_chain ───────────────────────────────────────


@pytest.mark.asyncio
async def test_dependency_chain_monitoring(graph: MagicMock, healthy_checker: AsyncMock):
    """Grafana depends on postgresql, prometheus, loki — all should be traced."""
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_dependency_chain("monitoring")

    assert result.name == "deps:monitoring"
    rooms = [h.room for h in result.hops]
    # Deepest-first: deps before monitoring, monitoring is last
    assert rooms[-1] == "monitoring"
    assert "postgresql" in rooms
    assert "prometheus" in rooms
    assert "loki" in rooms
    assert result.healthy is True


@pytest.mark.asyncio
async def test_dependency_chain_no_deps(graph: MagicMock, healthy_checker: AsyncMock):
    """postgresql has no deps — chain is just itself."""
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_dependency_chain("postgresql")

    assert len(result.hops) == 1
    assert result.hops[0].room == "postgresql"


@pytest.mark.asyncio
async def test_dependency_chain_transitive(graph: MagicMock, healthy_checker: AsyncMock):
    """panel depends on my-service + postgresql; my-service depends on postgresql + influxdb."""
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_dependency_chain("panel")

    rooms = [h.room for h in result.hops]
    assert rooms[-1] == "panel"
    # postgresql and influxdb (my-service deps) should appear before my-service
    assert "postgresql" in rooms
    assert "influxdb" in rooms
    assert "my-service" in rooms


@pytest.mark.asyncio
async def test_dependency_chain_broken_upstream(graph: MagicMock):
    async def checker(room: str) -> dict:
        if room == "postgresql":
            return {"status": "unhealthy", "detail": "connection timeout"}
        return {"status": "healthy", "detail": "OK"}

    tracer = DiagnosticTracer(graph, health_checker=checker)
    result = await tracer.trace_dependency_chain("monitoring")

    assert result.healthy is False
    assert result.broken_at == "postgresql"


@pytest.mark.asyncio
async def test_dependency_chain_unknown_room(graph: MagicMock, healthy_checker: AsyncMock):
    tracer = DiagnosticTracer(graph, health_checker=healthy_checker)
    result = await tracer.trace_dependency_chain("nonexistent")

    assert result.healthy is False
    assert result.hops[0].status == "unreachable"


# ── TraceResult properties ───────────────────────────────────────


def test_trace_result_broken_at_first_unhealthy():
    hops = [
        TraceHop(room="a", status="healthy", detail="OK"),
        TraceHop(room="b", status="unhealthy", detail="down"),
        TraceHop(room="c", status="unreachable", detail="timeout"),
    ]
    result = TraceResult(name="test", hops=hops, healthy=False)
    assert result.broken_at == "b"


def test_trace_result_broken_at_none_when_healthy():
    hops = [
        TraceHop(room="a", status="healthy", detail="OK"),
        TraceHop(room="b", status="healthy", detail="OK"),
    ]
    result = TraceResult(name="test", hops=hops, healthy=True)
    assert result.broken_at is None


# ── available_pipelines ──────────────────────────────────────────


def test_available_pipelines(graph: MagicMock):
    tracer = DiagnosticTracer(graph)
    pipelines = tracer.available_pipelines
    assert "plc_to_monitoring" in pipelines
    assert "metrics" in pipelines
    assert "logs" in pipelines
    assert "plc_to_dashboard" in pipelines


# ── latency and metadata passthrough ────────────────────────────


@pytest.mark.asyncio
async def test_probe_captures_latency_and_metadata(graph: MagicMock):
    async def checker(room: str) -> dict:
        return {
            "status": "healthy",
            "detail": "responding",
            "latency_ms": 42.5,
            "version": "18.1",
        }

    tracer = DiagnosticTracer(graph, health_checker=checker)
    result = await tracer.trace_data_pipeline("my-service,postgresql")

    assert result.hops[0].latency_ms == 42.5
    assert result.hops[0].metadata == {"version": "18.1"}
