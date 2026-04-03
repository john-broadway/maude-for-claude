"""Tests for BriefingGenerator — template-based cross-room summaries."""

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.healing.dependencies import DependencyGraph

_FIXTURE_YAML = Path(__file__).parent / "fixtures" / "dependencies.yaml"


@pytest.fixture
def mock_memory() -> AsyncMock:
    memory = AsyncMock(spec=CrossRoomMemory)
    memory.all_rooms_summary = AsyncMock(return_value=[])
    memory.recent_incidents = AsyncMock(return_value=[])
    memory.recent_escalations = AsyncMock(return_value=[])
    memory.recent_restarts = AsyncMock(return_value=[])
    memory.recent_remediations = AsyncMock(return_value=[])
    return memory


@pytest.fixture
def deps() -> DependencyGraph:
    return DependencyGraph(yaml_path=_FIXTURE_YAML)


@pytest.fixture
def briefing(mock_memory: AsyncMock, deps: DependencyGraph) -> BriefingGenerator:
    return BriefingGenerator(memory=mock_memory, deps=deps)


# ── Empty hotel ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_empty_briefing(briefing: BriefingGenerator):
    """No activity should produce a clean briefing."""
    output = await briefing.generate()
    assert "Coordinator Briefing" in output
    assert "UNHEALTHY ROOMS: none" in output
    assert "INCIDENTS:" in output
    assert "ESCALATIONS:" in output
    assert "none" in output


# ── Healthy rooms ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_healthy_rooms_listed(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "postgresql",
            "total_runs": 5,
            "resolved": 2,
            "failed": 0,
            "escalated": 0,
            "no_action": 3,
            "last_activity": "2026-02-01T10:00:00",
        },
        {
            "project": "example-scada",
            "total_runs": 3,
            "resolved": 1,
            "failed": 0,
            "escalated": 0,
            "no_action": 2,
            "last_activity": "2026-02-01T10:05:00",
        },
    ]
    output = await briefing.generate()
    assert "ALL CLEAR:" in output
    assert "postgresql" in output
    assert "example-scada" in output


# ── Unhealthy rooms ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_unhealthy_rooms_highlighted(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "example-scada",
            "total_runs": 5,
            "resolved": 1,
            "failed": 2,
            "escalated": 0,
            "no_action": 2,
            "last_activity": "2026-02-01T10:00:00",
        },
    ]
    output = await briefing.generate()
    assert "UNHEALTHY ROOMS:" in output
    assert "example-scada" in output
    assert "2 failed" in output


# ── Incidents in output ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_incidents_displayed(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.recent_incidents.return_value = [
        {
            "project": "grafana",
            "summary": "Datasource connection refused",
            "outcome": "resolved",
            "created_at": "2026-02-01T14:30:00+00:00",
        },
    ]
    output = await briefing.generate()
    assert "grafana" in output
    assert "Datasource connection refused" in output


# ── Scoped to single room ────────────────────────────────────────


@pytest.mark.asyncio
async def test_scoped_to_single_room(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "example-scada",
            "total_runs": 3,
            "resolved": 1,
            "failed": 0,
            "escalated": 0,
            "no_action": 2,
        },
        {
            "project": "grafana",
            "total_runs": 2,
            "resolved": 1,
            "failed": 1,
            "escalated": 0,
            "no_action": 0,
        },
    ]
    output = await briefing.generate(scope="room:example-scada")
    # Only example-scada should appear in room-scoped output
    assert "DEPENDENCIES FOR example-scada" in output


# ── Dependencies at risk ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_dependencies_at_risk(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "postgresql",
            "total_runs": 5,
            "resolved": 0,
            "failed": 3,
            "escalated": 0,
            "no_action": 2,
        },
    ]
    output = await briefing.generate()
    assert "DEPENDENCIES AT RISK:" in output
    assert "postgresql" in output
    # postgresql affects my-service, panel, monitoring, and others
    assert "my-service" in output


# ── Room status grid ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_room_status_grid(briefing: BriefingGenerator, mock_memory: AsyncMock):
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "postgresql",
            "total_runs": 5,
            "resolved": 2,
            "failed": 0,
            "escalated": 0,
            "no_action": 3,
        },
    ]
    output = await briefing.room_status()
    assert "ROOM STATUS GRID" in output
    assert "postgresql" in output
    assert "ok" in output


# ── _format_time ──────────────────────────────────────────────────


def test_format_time_iso_string():
    result = BriefingGenerator._format_time("2026-02-01T14:30:00+00:00")
    assert result == "14:30"


def test_format_time_empty():
    result = BriefingGenerator._format_time("")
    assert result == "??:??"


def test_format_time_none():
    result = BriefingGenerator._format_time(None)
    assert result == "??:??"


# ── Custom minutes window ─────────────────────────────────────────


@pytest.mark.asyncio
async def test_custom_minutes(briefing: BriefingGenerator, mock_memory: AsyncMock):
    await briefing.generate(minutes=480)
    assert "480" in str(mock_memory.all_rooms_summary.call_args)


# ── Unhealthy rooms with escalations and restarts (lines 77, 80) ──


@pytest.mark.asyncio
async def test_unhealthy_room_with_escalations_and_restarts(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Unhealthy room showing escalated count and restart count."""
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "example-scada",
            "total_runs": 5,
            "resolved": 0,
            "failed": 1,
            "escalated": 2,
            "no_action": 2,
        },
    ]
    mock_memory.recent_restarts.return_value = [
        {
            "project": "example-scada",
            "tool": "service_restart",
            "created_at": "2026-02-01T10:00:00",
        },
        {
            "project": "example-scada",
            "tool": "service_restart",
            "created_at": "2026-02-01T10:05:00",
        },
    ]
    output = await briefing.generate()
    assert "2 escalated" in output
    assert "2 restart(s)" in output
    assert "1 failed" in output


# ── Escalation formatting (lines 118-122) ────────────────────────


@pytest.mark.asyncio
async def test_escalations_displayed(briefing: BriefingGenerator, mock_memory: AsyncMock):
    """Escalations should be formatted with timestamp and room name."""
    mock_memory.recent_escalations.return_value = [
        {
            "project": "grafana",
            "summary": "Datasource timeout after 3 retries",
            "created_at": "2026-02-01T15:45:00+00:00",
        },
    ]
    output = await briefing.generate()
    assert "grafana" in output
    assert "Datasource timeout" in output
    assert "15:45" in output


# ── Dependency for target_room (line 138) ─────────────────────────


@pytest.mark.asyncio
async def test_scoped_room_no_dependencies(mock_memory: AsyncMock):
    """A room with no dependencies should say 'No dependencies'."""
    # Use a DependencyGraph with no deps for the target room
    deps = DependencyGraph(yaml_path=_FIXTURE_YAML)
    briefing = BriefingGenerator(memory=mock_memory, deps=deps)
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "ollama",
            "total_runs": 1,
            "resolved": 1,
            "failed": 0,
            "escalated": 0,
            "no_action": 0,
        },
    ]
    output = await briefing.generate(scope="room:ollama")
    assert "No dependencies" in output


# ── affected_by with no downstream deps (line 149) ───────────────


@pytest.mark.asyncio
async def test_unhealthy_room_no_downstream_deps(mock_memory: AsyncMock):
    """Unhealthy room with no downstream dependencies."""
    deps = DependencyGraph(yaml_path=_FIXTURE_YAML)
    briefing = BriefingGenerator(memory=mock_memory, deps=deps)
    # hmi has no depended_by in default graph
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "hmi",
            "total_runs": 3,
            "resolved": 0,
            "failed": 2,
            "escalated": 0,
            "no_action": 1,
        },
    ]
    output = await briefing.generate()
    assert "hmi" in output
    assert "no downstream dependencies" in output


# ── room_status ATTENTION line (line 166) ─────────────────────────


@pytest.mark.asyncio
async def test_room_status_attention(briefing: BriefingGenerator, mock_memory: AsyncMock):
    """Rooms with failures should show ATTENTION in status grid."""
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "my-service",
            "total_runs": 5,
            "resolved": 1,
            "failed": 2,
            "escalated": 1,
            "no_action": 1,
        },
    ]
    output = await briefing.room_status()
    assert "ATTENTION" in output
    assert "failed=2" in output
    assert "escalated=1" in output


# ── _format_time with bad string (lines 186-187) ─────────────────


def test_format_time_bad_string():
    """Non-ISO string should return first 5 chars."""
    result = BriefingGenerator._format_time("not-a-date-at-all")
    assert result == "not-a"


# ── _format_time with datetime object (line 189) ─────────────────


def test_format_time_datetime_object():
    """datetime object should format as HH:MM."""
    from datetime import datetime

    dt = datetime(2026, 2, 1, 14, 30, 0)
    result = BriefingGenerator._format_time(dt)
    assert result == "14:30"


# ── Autonomous fixes section ─────────────────────────────────────


@pytest.mark.asyncio
async def test_briefing_autonomous_fixes_section(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """AUTONOMOUS FIXES section appears in briefing."""
    mock_memory.recent_remediations.return_value = [
        {
            "project": "prometheus",
            "summary": "Restarted prometheus, health check passed",
            "created_at": "2026-02-01T16:00:00+00:00",
        },
    ]
    output = await briefing.generate()
    assert "AUTONOMOUS FIXES:" in output
    assert "prometheus" in output
    assert "Restarted prometheus" in output
    assert "16:00" in output


@pytest.mark.asyncio
async def test_briefing_autonomous_fixes_empty(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """AUTONOMOUS FIXES section shows 'none' when no remediations."""
    output = await briefing.generate()
    assert "AUTONOMOUS FIXES:" in output
    # The "none" under AUTONOMOUS FIXES
    lines = output.split("\n")
    fixes_idx = next(i for i, line in enumerate(lines) if "AUTONOMOUS FIXES:" in line)
    assert "none" in lines[fixes_idx + 1]


@pytest.mark.asyncio
async def test_briefing_section_order(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Sections appear in correct order: INCIDENTS → AUTONOMOUS FIXES → ESCALATIONS."""
    output = await briefing.generate()
    incidents_pos = output.index("INCIDENTS:")
    fixes_pos = output.index("AUTONOMOUS FIXES:")
    escalations_pos = output.index("ESCALATIONS:")
    assert incidents_pos < fixes_pos < escalations_pos


@pytest.mark.asyncio
async def test_briefing_remediations_scoped_to_room(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Room-scoped briefing filters remediations."""
    mock_memory.recent_remediations.return_value = [
        {
            "project": "prometheus",
            "summary": "Fixed prometheus",
            "created_at": "2026-02-01T16:00:00",
        },
        {"project": "grafana", "summary": "Fixed grafana", "created_at": "2026-02-01T16:05:00"},
    ]
    output = await briefing.generate(scope="room:prometheus")
    assert "Fixed prometheus" in output
    assert "Fixed grafana" not in output


# ── Room status grid with remediated count ───────────────────────


@pytest.mark.asyncio
async def test_room_status_shows_remediated_count(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Room status grid includes remediated count when > 0."""
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "prometheus",
            "total_runs": 10,
            "resolved": 3,
            "failed": 0,
            "escalated": 0,
            "no_action": 5,
            "remediated": 2,
        },
    ]
    output = await briefing.room_status()
    assert "remediated=2" in output


# ── Edge cases ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_analytics_insights_injected(mock_memory: AsyncMock, deps: DependencyGraph):
    """When analytics is wired, INSIGHTS section appears in briefing."""
    mock_analytics = AsyncMock()
    mock_analytics.analyze.return_value = [
        "grafana: 5 incidents, 2 failed in last 60min",
        "gpu-node-1: trending up — 6 incidents vs 2 prior period (+200%)",
    ]
    gen = BriefingGenerator(memory=mock_memory, deps=deps, analytics=mock_analytics)
    output = await gen.generate()
    assert "INSIGHTS:" in output
    assert "grafana: 5 incidents" in output
    assert "gpu-node-1: trending up" in output


@pytest.mark.asyncio
async def test_analytics_empty_no_section(mock_memory: AsyncMock, deps: DependencyGraph):
    """When analytics returns no insights, INSIGHTS section is omitted."""
    mock_analytics = AsyncMock()
    mock_analytics.analyze.return_value = []
    gen = BriefingGenerator(memory=mock_memory, deps=deps, analytics=mock_analytics)
    output = await gen.generate()
    assert "INSIGHTS:" not in output


@pytest.mark.asyncio
async def test_analytics_failure_non_fatal(mock_memory: AsyncMock, deps: DependencyGraph):
    """Analytics failure doesn't crash the briefing."""
    mock_analytics = AsyncMock()
    mock_analytics.analyze.side_effect = RuntimeError("PG down")
    gen = BriefingGenerator(memory=mock_memory, deps=deps, analytics=mock_analytics)
    output = await gen.generate()
    assert "Coordinator Briefing" in output  # Briefing still generated
    assert "INSIGHTS:" not in output


@pytest.mark.asyncio
async def test_hotel_scope_without_cross_site(mock_memory: AsyncMock, deps: DependencyGraph):
    """Hotel scope without CrossSiteMemory returns error message."""
    gen = BriefingGenerator(memory=mock_memory, deps=deps, cross_site=None)
    output = await gen.generate(scope="hotel")
    assert "not configured" in output


@pytest.mark.asyncio
async def test_remote_site_scope_without_cross_site(
    mock_memory: AsyncMock,
    deps: DependencyGraph,
):
    """Remote site scope without CrossSiteMemory returns error message."""
    gen = BriefingGenerator(memory=mock_memory, deps=deps, cross_site=None)
    output = await gen.generate(scope="site:site-b")
    assert "not configured" in output


@pytest.mark.asyncio
async def test_briefing_truncates_long_summaries(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Incident summaries longer than 120 chars are truncated."""
    long_summary = "A" * 200
    mock_memory.recent_incidents.return_value = [
        {
            "project": "dns",
            "summary": long_summary,
            "outcome": "failed",
            "created_at": "2026-02-01T10:00:00",
        },
    ]
    output = await briefing.generate()
    # The summary in output should be at most 120 chars of the original
    assert "A" * 121 not in output
    assert "A" * 100 in output


@pytest.mark.asyncio
async def test_webhook_not_fired_when_all_healthy(
    mock_memory: AsyncMock,
    deps: DependencyGraph,
):
    """Webhook should not fire when all rooms are healthy."""
    gen = BriefingGenerator(
        memory=mock_memory,
        deps=deps,
        alert_webhook_url="http://fake/hook",
    )
    mock_memory.all_rooms_summary.return_value = [
        {"project": "dns", "total_runs": 5, "resolved": 5, "failed": 0, "escalated": 0},
    ]
    # If webhook fired, it would try to POST — since mock_memory doesn't
    # set up httpx, no error means webhook wasn't attempted
    output = await gen.generate()
    assert "UNHEALTHY ROOMS: none" in output


@pytest.mark.asyncio
async def test_room_status_grid_quiet_rooms(
    briefing: BriefingGenerator,
    mock_memory: AsyncMock,
):
    """Rooms with no activity show as 'quiet' in the grid."""
    mock_memory.all_rooms_summary.return_value = []  # No activity at all
    output = await briefing.room_status()
    assert "quiet" in output


# ── Webhook timeout / error handling ───────────────────────────────


@pytest.mark.asyncio
async def test_webhook_fires_on_unhealthy_rooms(
    mock_memory: AsyncMock,
    deps: DependencyGraph,
):
    """Webhook fires (as background task) when rooms are unhealthy."""
    from unittest.mock import patch

    gen = BriefingGenerator(
        memory=mock_memory,
        deps=deps,
        alert_webhook_url="http://fake/hook",
    )
    mock_memory.all_rooms_summary.return_value = [
        {
            "project": "example-scada",
            "total_runs": 5,
            "resolved": 0,
            "failed": 3,
            "escalated": 0,
            "no_action": 2,
        },
    ]

    with patch.object(gen, "_post_webhook", new_callable=AsyncMock) as mock_hook:
        output = await gen.generate()
        # Allow background task to complete
        await asyncio.sleep(0.05)

    assert "UNHEALTHY" in output
    mock_hook.assert_called_once()
    args = mock_hook.call_args[0][0]
    assert any("example-scada" in r for r in args)


@pytest.mark.asyncio
async def test_webhook_connection_refused_is_swallowed():
    """Connection refused to webhook URL is caught, not propagated."""

    gen = BriefingGenerator(
        memory=AsyncMock(),
        deps=DependencyGraph(yaml_path=_FIXTURE_YAML),
        alert_webhook_url="http://192.0.2.1:1/hook",  # RFC 5737 TEST-NET
    )
    # _post_webhook should catch the connection error
    await gen._post_webhook(["example-scada", "grafana"])
    # If we get here, the exception was swallowed — test passes


@pytest.mark.asyncio
async def test_webhook_timeout_is_swallowed():
    """httpx timeout on webhook is caught, not propagated."""
    from unittest.mock import patch

    import httpx

    gen = BriefingGenerator(
        memory=AsyncMock(),
        deps=DependencyGraph(yaml_path=_FIXTURE_YAML),
        alert_webhook_url="http://fake/hook",
    )

    async def mock_post(*args, **kwargs):
        raise httpx.ReadTimeout("timed out")

    with patch("httpx.AsyncClient.post", side_effect=mock_post):
        # Should not raise
        await gen._post_webhook(["example-scada"])


@pytest.mark.asyncio
async def test_webhook_payload_format():
    """Webhook payload contains room count and room list."""
    from unittest.mock import patch

    import httpx

    gen = BriefingGenerator(
        memory=AsyncMock(),
        deps=DependencyGraph(yaml_path=_FIXTURE_YAML),
        alert_webhook_url="http://fake/hook",
    )

    captured_payload = {}

    async def capture_post(url, json=None, **kwargs):
        captured_payload.update(json or {})
        return httpx.Response(200)

    with patch("httpx.AsyncClient.post", side_effect=capture_post):
        await gen._post_webhook(["example-scada", "grafana"])

    assert captured_payload["text"] == "Coordinator: 2 room(s) unhealthy"
    assert captured_payload["rooms"] == ["example-scada", "grafana"]
