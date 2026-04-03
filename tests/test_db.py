# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.db — LazyPool and format_json."""

import json
import time
from datetime import datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.db import LazyPool, format_json
from maude.db.formatting import format_json as format_json_direct  # noqa: I001
from maude.db.pool import LazyPool as LazyPoolDirect

# ── format_json ──────────────────────────────────────────


def test_format_json_dict():
    result = format_json({"key": "value"})
    assert json.loads(result) == {"key": "value"}


def test_format_json_list():
    result = format_json([1, 2, 3])
    assert json.loads(result) == [1, 2, 3]


def test_format_json_indent():
    result = format_json({"a": 1})
    assert "\n" in result  # pretty-printed


def test_format_json_default_str():
    dt = datetime(2026, 1, 1, 12, 0, 0)
    result = format_json({"ts": dt})
    parsed = json.loads(result)
    assert "2026" in parsed["ts"]


def test_format_json_reexport():
    assert format_json is format_json_direct


# ── LazyPool ─────────────────────────────────────────────


def test_lazy_pool_reexport():
    assert LazyPool is LazyPoolDirect


_POOL_CREATE = "maude.db.pool.asyncpg.create_pool"
_POOL_KWARGS = "maude.db.pool.pg_pool_kwargs"


_FAKE_PG_KWARGS = {
    "host": "localhost", "port": 5432, "database": "agent",
    "user": "test", "password": "test", "min_size": 1, "max_size": 5,
}


@pytest.mark.asyncio
async def test_lazy_pool_creates_on_first_get():
    pool = LazyPool(database="agent", suppress_errors=False)
    mock_pool = MagicMock()

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(_POOL_CREATE, new_callable=AsyncMock, return_value=mock_pool):
        result = await pool.get()

    assert result is mock_pool


@pytest.mark.asyncio
async def test_lazy_pool_reuses_pool():
    pool = LazyPool(database="agent", suppress_errors=False)
    mock_pool = MagicMock()

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
        _POOL_CREATE, new_callable=AsyncMock, return_value=mock_pool,
    ) as create:
        first = await pool.get()
        second = await pool.get()

    assert first is second
    create.assert_called_once()


@pytest.mark.asyncio
async def test_lazy_pool_suppress_errors():
    pool = LazyPool(database="agent", suppress_errors=True)

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
        _POOL_CREATE, new_callable=AsyncMock,
        side_effect=ConnectionError("nope"),
    ):
        result = await pool.get()

    assert result is None


@pytest.mark.asyncio
async def test_lazy_pool_strict_propagates():
    pool = LazyPool(database="agent", suppress_errors=False)

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
            _POOL_CREATE, new_callable=AsyncMock,
            side_effect=ConnectionError("nope"),
        ), \
         pytest.raises(ConnectionError):
        await pool.get()


@pytest.mark.asyncio
async def test_lazy_pool_close():
    pool = LazyPool(database="agent")
    mock_pool = MagicMock()
    mock_pool.close = AsyncMock()
    pool._pool = mock_pool

    await pool.close()

    mock_pool.close.assert_called_once()
    assert pool._pool is None


@pytest.mark.asyncio
async def test_lazy_pool_close_noop_when_none():
    pool = LazyPool(database="agent")
    await pool.close()  # Should not raise


@pytest.mark.asyncio
async def test_lazy_pool_passes_kwargs():
    pool = LazyPool(
        database="mydb", db_host="1.2.3.4",
        min_size=2, max_size=5, suppress_errors=False,
    )
    kw_ret = {"host": "1.2.3.4", "database": "mydb"}

    with (
        patch(_POOL_CREATE, new_callable=AsyncMock, return_value=MagicMock()),
        patch(_POOL_KWARGS, return_value=kw_ret) as kwargs_fn,
    ):
        await pool.get()

    kwargs_fn.assert_called_once_with(
        db_host="1.2.3.4", database="mydb", min_size=2, max_size=5,
    )


# ── Retry cooldown ──────────────────────────────────────


@pytest.mark.asyncio
async def test_lazy_pool_cooldown_blocks_immediate_retry():
    pool = LazyPool(database="agent", suppress_errors=True, retry_cooldown=30.0)

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
        _POOL_CREATE, new_callable=AsyncMock,
        side_effect=ConnectionError("down"),
    ) as create:
        first = await pool.get()
        assert first is None
        create.assert_called_once()

        second = await pool.get()
        assert second is None
        # Still only one call — cooldown blocked the retry
        create.assert_called_once()


@pytest.mark.asyncio
async def test_lazy_pool_cooldown_expires_allows_retry():
    pool = LazyPool(database="agent", suppress_errors=True, retry_cooldown=10.0)

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
        _POOL_CREATE, new_callable=AsyncMock,
        side_effect=ConnectionError("down"),
    ) as create:
        await pool.get()
        create.assert_called_once()

        # Simulate cooldown expiry
        pool._last_failure = time.monotonic() - 11.0

        await pool.get()
        assert create.call_count == 2


@pytest.mark.asyncio
async def test_lazy_pool_success_resets_failure_timer():
    pool = LazyPool(database="agent", suppress_errors=True, retry_cooldown=30.0)
    mock_pool = MagicMock()

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(_POOL_CREATE, new_callable=AsyncMock) as create:
        # First call fails
        create.side_effect = ConnectionError("down")
        await pool.get()
        assert pool._last_failure > 0

        # Expire cooldown and succeed
        pool._last_failure = time.monotonic() - 31.0
        create.side_effect = None
        create.return_value = mock_pool
        result = await pool.get()

    assert result is mock_pool
    assert pool._last_failure == 0.0


@pytest.mark.asyncio
async def test_lazy_pool_strict_mode_still_records_failure_time():
    pool = LazyPool(database="agent", suppress_errors=False, retry_cooldown=30.0)

    with patch(_POOL_KWARGS, return_value=_FAKE_PG_KWARGS), \
         patch(
        _POOL_CREATE, new_callable=AsyncMock,
        side_effect=ConnectionError("down"),
    ):
        with pytest.raises(ConnectionError):
            await pool.get()

    assert pool._last_failure > 0
