# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for Coordinator CLI — argument parsing and subcommand dispatch."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.coordination.cli import _briefing, _deps, _escalations, _incidents, _status, main

# ── Argument parsing via main() ──────────────────────────────────


def test_no_command_exits(capsys: pytest.CaptureFixture[str]):
    """No subcommand should print help and exit 1."""
    with patch("sys.argv", ["maude-coordinator"]):
        with pytest.raises(SystemExit, match="1"):
            main()


# ── briefing subcommand ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_briefing_defaults(capsys: pytest.CaptureFixture[str]):
    """briefing with defaults should call generate(scope='all', minutes=60)."""
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_gen = AsyncMock()
    mock_gen.generate = AsyncMock(return_value="== Briefing ==")

    with (
        patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory),
        patch("maude.coordination.cli.BriefingGenerator", return_value=mock_gen),
    ):
        args = MagicMock()
        args.scope = "all"
        args.minutes = 60
        await _briefing(args)

    mock_gen.generate.assert_awaited_once_with(scope="all", minutes=60)
    mock_memory.close.assert_awaited_once()
    captured = capsys.readouterr()
    assert "== Briefing ==" in captured.out


@pytest.mark.asyncio
async def test_briefing_custom_scope(capsys: pytest.CaptureFixture[str]):
    """briefing with --scope room:my-service should pass it through."""
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_gen = AsyncMock()
    mock_gen.generate = AsyncMock(return_value="my-service report")

    with (
        patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory),
        patch("maude.coordination.cli.BriefingGenerator", return_value=mock_gen),
    ):
        args = MagicMock()
        args.scope = "room:my-service"
        args.minutes = 480
        await _briefing(args)

    mock_gen.generate.assert_awaited_once_with(scope="room:my-service", minutes=480)


# ── status subcommand ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_status(capsys: pytest.CaptureFixture[str]):
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_gen = AsyncMock()
    mock_gen.room_status = AsyncMock(return_value="ROOM STATUS GRID\npostgresql ok")

    with (
        patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory),
        patch("maude.coordination.cli.BriefingGenerator", return_value=mock_gen),
    ):
        args = MagicMock()
        args.minutes = 60
        await _status(args)

    mock_gen.room_status.assert_awaited_once_with(minutes=60)
    mock_memory.close.assert_awaited_once()
    captured = capsys.readouterr()
    assert "ROOM STATUS GRID" in captured.out


# ── deps subcommand ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_deps_full_graph(capsys: pytest.CaptureFixture[str]):
    """deps with no room arg should dump the full graph."""
    with patch("maude.coordination.cli.DependencyGraph") as MockDeps:
        mock_deps = MockDeps.return_value
        mock_deps.to_dict.return_value = {"postgresql": {"depends_on": []}}

        args = MagicMock()
        args.room = ""
        await _deps(args)

    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert "postgresql" in data


@pytest.mark.asyncio
async def test_deps_single_room(capsys: pytest.CaptureFixture[str]):
    """deps with a room name should show that room's dependencies."""
    with patch("maude.coordination.cli.DependencyGraph") as MockDeps:
        mock_deps = MockDeps.return_value
        mock_deps.depends_on.return_value = ["postgresql"]
        mock_deps.depended_by.return_value = ["hmi"]
        mock_deps.affected_by.return_value = ["postgresql"]

        args = MagicMock()
        args.room = "my-service"
        await _deps(args)

    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["room"] == "my-service"
    assert "postgresql" in data["depends_on"]
    assert "hmi" in data["depended_by"]


# ── incidents subcommand ─────────────────────────────────────────


@pytest.mark.asyncio
async def test_incidents_empty(capsys: pytest.CaptureFixture[str]):
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_memory.recent_incidents = AsyncMock(return_value=[])

    with patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory):
        args = MagicMock()
        args.minutes = 60
        await _incidents(args)

    captured = capsys.readouterr()
    assert "No incidents" in captured.out


@pytest.mark.asyncio
async def test_incidents_with_data(capsys: pytest.CaptureFixture[str]):
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_memory.recent_incidents = AsyncMock(
        return_value=[
            {
                "created_at": "2026-02-01T14:30:00",
                "project": "monitoring",
                "summary": "Connection timeout",
                "outcome": "resolved",
            },
        ]
    )

    with patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory):
        args = MagicMock()
        args.minutes = 120
        await _incidents(args)

    captured = capsys.readouterr()
    assert "monitoring" in captured.out
    assert "Connection timeout" in captured.out
    assert "[resolved]" in captured.out


# ── escalations subcommand ───────────────────────────────────────


@pytest.mark.asyncio
async def test_escalations_empty(capsys: pytest.CaptureFixture[str]):
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_memory.recent_escalations = AsyncMock(return_value=[])

    with patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory):
        args = MagicMock()
        args.minutes = 60
        await _escalations(args)

    captured = capsys.readouterr()
    assert "No escalations" in captured.out


@pytest.mark.asyncio
async def test_escalations_with_data(capsys: pytest.CaptureFixture[str]):
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_memory.recent_escalations = AsyncMock(
        return_value=[
            {
                "created_at": "2026-02-01T15:00:00",
                "project": "my-service",
                "summary": "Service unreachable after 3 retries",
            },
        ]
    )

    with patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory):
        args = MagicMock()
        args.minutes = 60
        await _escalations(args)

    captured = capsys.readouterr()
    assert "my-service" in captured.out
    assert "Service unreachable" in captured.out


# ── memory.close() called even on error ──────────────────────────


@pytest.mark.asyncio
async def test_briefing_closes_memory_on_error():
    """memory.close() should be called even when generate() raises."""
    mock_memory = AsyncMock()
    mock_memory.close = AsyncMock()
    mock_gen = AsyncMock()
    mock_gen.generate = AsyncMock(side_effect=RuntimeError("boom"))

    with (
        patch("maude.coordination.cli.CrossRoomMemory", return_value=mock_memory),
        patch("maude.coordination.cli.BriefingGenerator", return_value=mock_gen),
    ):
        args = MagicMock()
        args.scope = "all"
        args.minutes = 60
        with pytest.raises(RuntimeError, match="boom"):
            await _briefing(args)

    mock_memory.close.assert_awaited_once()
