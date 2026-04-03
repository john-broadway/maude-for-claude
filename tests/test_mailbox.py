# Tests for room mailbox — lightweight inter-room notifications.
# Version: 1.0.0
# Created: 2026-04-02 16:10 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Tests for maude.infra.mailbox — fire-and-forget messaging."""

from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest

from maude.infra.mailbox import PRIORITIES, RoomMailbox

# ── send ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_send_returns_id():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=42)
    mailbox._db._pool = mock_pool

    msg_id = await mailbox.send("postgresql", "Service restarted")

    assert msg_id == 42
    mock_pool.fetchval.assert_awaited_once()
    args = mock_pool.fetchval.call_args[0]
    assert args[1] == "example-scada"  # from_room
    assert args[2] == "postgresql"  # to_room
    assert args[3] == "Service restarted"  # message
    assert args[4] == "info"  # default priority


@pytest.mark.asyncio
async def test_send_with_priority():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=1)
    mailbox._db._pool = mock_pool

    await mailbox.send("grafana", "Disk at 90%", priority="warning")

    args = mock_pool.fetchval.call_args[0]
    assert args[4] == "warning"


@pytest.mark.asyncio
async def test_send_invalid_priority_defaults_to_info():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=1)
    mailbox._db._pool = mock_pool

    await mailbox.send("grafana", "Test", priority="bogus")

    args = mock_pool.fetchval.call_args[0]
    assert args[4] == "info"


@pytest.mark.asyncio
async def test_send_truncates_long_messages():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=1)
    mailbox._db._pool = mock_pool

    await mailbox.send("grafana", "x" * 5000)

    args = mock_pool.fetchval.call_args[0]
    assert len(args[3]) == 2000


@pytest.mark.asyncio
async def test_send_returns_none_on_pool_unavailable():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db._pool = None

    result = await mailbox.send("grafana", "Test")

    assert result is None


@pytest.mark.asyncio
async def test_send_returns_none_on_exception():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(side_effect=Exception("PG down"))
    mailbox._db._pool = mock_pool

    result = await mailbox.send("grafana", "Test")

    assert result is None


# ── check ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_check_returns_messages():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(
        return_value=[
            {
                "id": 1,
                "from_room": "postgresql",
                "message": "Restarted",
                "priority": "info",
                "created_at": datetime(2026, 4, 2, tzinfo=timezone.utc),
            },
            {
                "id": 2,
                "from_room": "grafana",
                "message": "Disk high",
                "priority": "warning",
                "created_at": datetime(2026, 4, 2, tzinfo=timezone.utc),
            },
        ]
    )
    mailbox._db._pool = mock_pool

    messages = await mailbox.check()

    assert len(messages) == 2
    assert messages[0]["from"] == "postgresql"
    assert messages[1]["priority"] == "warning"


@pytest.mark.asyncio
async def test_check_returns_empty_on_pool_unavailable():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db._pool = None

    assert await mailbox.check() == []


@pytest.mark.asyncio
async def test_check_returns_empty_on_exception():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(side_effect=Exception("PG down"))
    mailbox._db._pool = mock_pool

    assert await mailbox.check() == []


# ── mark_read ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_mark_read_returns_count():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(return_value="UPDATE 3")
    mailbox._db._pool = mock_pool

    count = await mailbox.mark_read([1, 2, 3])

    assert count == 3
    args = mock_pool.execute.call_args[0]
    assert args[1] == [1, 2, 3]
    assert args[2] == "example-scada"


@pytest.mark.asyncio
async def test_mark_read_empty_list():
    mailbox = RoomMailbox(project="example-scada")
    assert await mailbox.mark_read([]) == 0


@pytest.mark.asyncio
async def test_mark_read_pool_unavailable():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db._pool = None
    assert await mailbox.mark_read([1]) == 0


# ── unread_count ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_unread_count():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetchval = AsyncMock(return_value=5)
    mailbox._db._pool = mock_pool

    assert await mailbox.unread_count() == 5


@pytest.mark.asyncio
async def test_unread_count_pool_unavailable():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db._pool = None
    assert await mailbox.unread_count() == 0


# ── prune_old ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_prune_old_returns_count():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock(return_value="DELETE 12")
    mailbox._db._pool = mock_pool

    assert await mailbox.prune_old() == 12


@pytest.mark.asyncio
async def test_prune_old_pool_unavailable():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db._pool = None
    assert await mailbox.prune_old() == 0


# ── format_briefing ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_format_briefing_with_messages():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(
        return_value=[
            {
                "id": 1,
                "from_room": "postgresql",
                "message": "Restarted after crash",
                "priority": "critical",
                "created_at": datetime(2026, 4, 2, tzinfo=timezone.utc),
            },
            {
                "id": 2,
                "from_room": "grafana",
                "message": "Dashboard updated",
                "priority": "info",
                "created_at": datetime(2026, 4, 2, tzinfo=timezone.utc),
            },
        ]
    )
    mailbox._db._pool = mock_pool

    briefing = await mailbox.format_briefing()

    assert "2 unread" in briefing
    assert "[CRITICAL]" in briefing
    assert "postgresql" in briefing
    assert "Restarted after crash" in briefing
    # Info messages don't get a tag
    assert "grafana" in briefing


@pytest.mark.asyncio
async def test_format_briefing_empty():
    mailbox = RoomMailbox(project="example-scada")
    mock_pool = AsyncMock()
    mock_pool.fetch = AsyncMock(return_value=[])
    mailbox._db._pool = mock_pool

    assert await mailbox.format_briefing() == ""


# ── constants ────────────────────────────────────────────────────────


def test_priorities():
    assert "info" in PRIORITIES
    assert "warning" in PRIORITIES
    assert "critical" in PRIORITIES


# ── close ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_delegates_to_pool():
    mailbox = RoomMailbox(project="example-scada")
    mailbox._db = AsyncMock()
    await mailbox.close()
    mailbox._db.close.assert_awaited_once()
