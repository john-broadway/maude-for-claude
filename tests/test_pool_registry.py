"""Tests for PoolRegistry — shared pool deduplication.

Version: 1.0.0
Created: 2026-04-02
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)
"""

from __future__ import annotations

import pytest

from maude.db.pool import LazyPool, PoolRegistry

# ── fixture: clean registry between tests ─────────────────────────


# ── deduplication ─────────────────────────────────────────────────


def test_same_database_returns_same_pool() -> None:
    pool1 = PoolRegistry.get("agent")
    pool2 = PoolRegistry.get("agent")
    assert pool1 is pool2


def test_different_database_returns_different_pool() -> None:
    pool1 = PoolRegistry.get("agent")
    pool2 = PoolRegistry.get("plc")
    assert pool1 is not pool2


def test_different_host_returns_different_pool() -> None:
    pool1 = PoolRegistry.get("agent", db_host="192.0.2.30")
    pool2 = PoolRegistry.get("agent", db_host="198.51.100.30")
    assert pool1 is not pool2


def test_same_database_and_host_returns_same_pool() -> None:
    pool1 = PoolRegistry.get("agent", db_host="192.0.2.30")
    pool2 = PoolRegistry.get("agent", db_host="192.0.2.30")
    assert pool1 is pool2


def test_default_host_deduplicates() -> None:
    pool1 = PoolRegistry.get("agent")
    pool2 = PoolRegistry.get("agent", db_host="")
    assert pool1 is pool2


# ── returns LazyPool instances ────────────────────────────────────


def test_returns_lazy_pool() -> None:
    pool = PoolRegistry.get("agent")
    assert isinstance(pool, LazyPool)


def test_pool_has_correct_database() -> None:
    pool = PoolRegistry.get("plc")
    assert pool._database == "plc"


def test_pool_has_correct_host() -> None:
    pool = PoolRegistry.get("agent", db_host="192.0.2.30")
    assert pool._db_host == "192.0.2.30"


# ── kwargs forwarded on first call only ───────────────────────────


def test_kwargs_applied_on_first_call() -> None:
    pool = PoolRegistry.get("agent", max_size=10, suppress_errors=False)
    assert pool._max_size == 10
    assert pool._suppress_errors is False


def test_kwargs_ignored_on_subsequent_calls() -> None:
    pool1 = PoolRegistry.get("agent", max_size=10)
    pool2 = PoolRegistry.get("agent", max_size=99)
    assert pool1 is pool2
    assert pool2._max_size == 10  # First call's kwargs win


# ── close_all ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_all_closes_pools() -> None:
    pool1 = PoolRegistry.get("agent")
    pool2 = PoolRegistry.get("plc")

    # Inject fake underlying pools to verify close is called
    from unittest.mock import AsyncMock

    fake1 = AsyncMock()
    fake2 = AsyncMock()
    pool1._pool = fake1
    pool2._pool = fake2

    await PoolRegistry.close_all()

    fake1.close.assert_awaited_once()
    fake2.close.assert_awaited_once()
    assert len(PoolRegistry._pools) == 0


@pytest.mark.asyncio
async def test_close_all_noop_when_empty() -> None:
    await PoolRegistry.close_all()  # Should not raise
    assert len(PoolRegistry._pools) == 0


@pytest.mark.asyncio
async def test_get_after_close_all_creates_new_pool() -> None:
    pool1 = PoolRegistry.get("agent")
    await PoolRegistry.close_all()

    pool2 = PoolRegistry.get("agent")
    assert pool1 is not pool2


# ── pool_count ────────────────────────────────────────────────────


def test_pool_count_empty() -> None:
    assert PoolRegistry.pool_count() == 0


def test_pool_count_tracks_registrations() -> None:
    PoolRegistry.get("agent")
    assert PoolRegistry.pool_count() == 1

    PoolRegistry.get("plc")
    assert PoolRegistry.pool_count() == 2

    PoolRegistry.get("agent")  # Dedup — no new pool
    assert PoolRegistry.pool_count() == 2
