"""Tests for LazyPool — lazy-initialized asyncpg connection pool.

Version: 1.0.0
Created: 2026-04-01 00:55 MST
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude (Anthropic)
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from maude.db.pool import LazyPool

# ── helpers ─────────────────────────────────────────────────────────


def _make_fake_pool() -> AsyncMock:
    """Create a fake asyncpg.Pool."""
    pool = AsyncMock()
    pool.close = AsyncMock()
    return pool


# ── lazy initialization ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_pool_not_created_until_get() -> None:
    lp = LazyPool(database="test", db_host="fake")
    assert lp._pool is None


@pytest.mark.asyncio
async def test_get_creates_pool_on_first_call() -> None:
    fake_pool = _make_fake_pool()

    with patch(
        "maude.db.pool.asyncpg.create_pool",
        new_callable=AsyncMock,
        return_value=fake_pool,
    ) as mock_create:
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            result = await lp.get()

    assert result is fake_pool
    mock_create.assert_awaited_once()


@pytest.mark.asyncio
async def test_get_returns_cached_pool_on_second_call() -> None:
    fake_pool = _make_fake_pool()

    with patch(
        "maude.db.pool.asyncpg.create_pool",
        new_callable=AsyncMock,
        return_value=fake_pool,
    ) as mock_create:
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            first = await lp.get()
            second = await lp.get()

    assert first is second
    mock_create.assert_awaited_once()  # Only created once


# ── double-check locking ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_concurrent_get_only_creates_one_pool() -> None:
    fake_pool = _make_fake_pool()
    call_count = 0

    async def slow_create(**kwargs):  # type: ignore[no-untyped-def]
        nonlocal call_count
        call_count += 1
        await asyncio.sleep(0.05)  # Simulate slow connection
        return fake_pool

    with patch("maude.db.pool.asyncpg.create_pool", side_effect=slow_create):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            results = await asyncio.gather(lp.get(), lp.get(), lp.get())

    assert all(r is fake_pool for r in results)
    assert call_count == 1


# ── error handling: suppress mode ──────────────────────────────────


@pytest.mark.asyncio
async def test_suppress_errors_returns_none_on_failure() -> None:
    with patch("maude.db.pool.asyncpg.create_pool", side_effect=ConnectionRefusedError("PG down")):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake", suppress_errors=True)
            result = await lp.get()

    assert result is None


@pytest.mark.asyncio
async def test_strict_mode_raises_on_failure() -> None:
    with patch("maude.db.pool.asyncpg.create_pool", side_effect=ConnectionRefusedError("PG down")):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake", suppress_errors=False)

            with pytest.raises(ConnectionRefusedError):
                await lp.get()


# ── retry cooldown ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_retry_cooldown_skips_during_window() -> None:
    with patch("maude.db.pool.asyncpg.create_pool", side_effect=ConnectionRefusedError("PG down")):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake", retry_cooldown=60.0)
            first = await lp.get()
            assert first is None

            # Second call within cooldown should return None immediately
            second = await lp.get()
            assert second is None


@pytest.mark.asyncio
async def test_retry_after_cooldown_expires() -> None:
    fake_pool = _make_fake_pool()
    call_count = 0

    async def fail_then_succeed(**kwargs):  # type: ignore[no-untyped-def]
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise ConnectionRefusedError("PG down")
        return fake_pool

    with patch("maude.db.pool.asyncpg.create_pool", side_effect=fail_then_succeed):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake", retry_cooldown=0.1)

            first = await lp.get()
            assert first is None

            await asyncio.sleep(0.15)  # Wait past cooldown

            second = await lp.get()
            assert second is fake_pool


@pytest.mark.asyncio
async def test_cooldown_resets_on_success() -> None:
    fake_pool = _make_fake_pool()

    with patch("maude.db.pool.asyncpg.create_pool", side_effect=ConnectionRefusedError("PG down")):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake", retry_cooldown=0.1)
            await lp.get()  # Fail, set cooldown
            assert lp._last_failure > 0

    # Now succeed
    with patch(
        "maude.db.pool.asyncpg.create_pool",
        new_callable=AsyncMock,
        return_value=fake_pool,
    ):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            await asyncio.sleep(0.15)
            result = await lp.get()
            assert result is fake_pool
            assert lp._last_failure == 0.0  # Reset on success


# ── close ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_closes_pool_and_resets() -> None:
    fake_pool = _make_fake_pool()

    with patch(
        "maude.db.pool.asyncpg.create_pool",
        new_callable=AsyncMock,
        return_value=fake_pool,
    ):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            await lp.get()

    await lp.close()
    assert lp._pool is None
    fake_pool.close.assert_awaited_once()


@pytest.mark.asyncio
async def test_close_noop_when_no_pool() -> None:
    lp = LazyPool(database="test", db_host="fake")
    await lp.close()  # Should not raise
    assert lp._pool is None


@pytest.mark.asyncio
async def test_get_after_close_recreates_pool() -> None:
    pool1 = _make_fake_pool()
    pool2 = _make_fake_pool()
    calls = iter([pool1, pool2])

    async def create(**kwargs):  # type: ignore[no-untyped-def]
        return next(calls)

    with patch("maude.db.pool.asyncpg.create_pool", side_effect=create):
        with patch("maude.db.pool.pg_pool_kwargs", return_value={"host": "fake"}):
            lp = LazyPool(database="test", db_host="fake")
            first = await lp.get()
            assert first is pool1

            await lp.close()

            second = await lp.get()
            assert second is pool2


# ── constructor defaults ───────────────────────────────────────────


def test_default_values() -> None:
    lp = LazyPool()
    assert lp._database == "agent"
    assert lp._min_size == 1
    assert lp._max_size == 3
    assert lp._suppress_errors is True
    assert lp._retry_cooldown == 30.0


def test_custom_values() -> None:
    lp = LazyPool(
        database="plc",
        db_host="192.0.2.30",
        min_size=5,
        max_size=20,
        suppress_errors=False,
        retry_cooldown=60.0,
    )
    assert lp._database == "plc"
    assert lp._db_host == "192.0.2.30"
    assert lp._min_size == 5
    assert lp._max_size == 20
    assert lp._suppress_errors is False
    assert lp._retry_cooldown == 60.0
