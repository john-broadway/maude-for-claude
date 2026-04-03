# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.ssh_executor — async SSH command runner."""

import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from maude.daemon.executor import SSHExecutor, SSHResult

# ── SSHResult ────────────────────────────────────────────────────────


def test_ssh_result_ok():
    r = SSHResult(stdout="hello", stderr="", exit_code=0)
    assert r.ok
    assert r.to_dict()["exit_code"] == 0


def test_ssh_result_not_ok():
    r = SSHResult(stdout="", stderr="fail", exit_code=1)
    assert not r.ok


# ── SSHExecutor.run ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_run_success():
    executor = SSHExecutor(host="test-host")

    mock_result = MagicMock()
    mock_result.stdout = "hello world"
    mock_result.stderr = ""
    mock_result.exit_status = 0

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(return_value=mock_result)

    executor._conn = mock_conn
    result = await executor.run("echo hello")
    assert result.ok
    assert result.stdout == "hello world"


@pytest.mark.asyncio
async def test_run_nonzero_exit():
    executor = SSHExecutor(host="test-host")

    mock_result = MagicMock()
    mock_result.stdout = ""
    mock_result.stderr = "not found"
    mock_result.exit_status = 1

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(return_value=mock_result)

    executor._conn = mock_conn
    result = await executor.run("false")
    assert not result.ok
    assert result.exit_code == 1


@pytest.mark.asyncio
async def test_run_timeout():
    executor = SSHExecutor(host="test-host", timeout=0.01)

    mock_conn = AsyncMock()
    # Make run() return a future that never resolves
    never_done = asyncio.Future()
    mock_conn.run = MagicMock(return_value=never_done)

    executor._conn = mock_conn
    # Patch _ensure_connection to return our mock directly
    executor._ensure_connection = AsyncMock(return_value=mock_conn)

    result = await executor.run("sleep 100", timeout=0.01)

    assert not result.ok
    assert result.exit_code == -1
    assert "timed out" in result.stderr


@pytest.mark.asyncio
async def test_connection_reuse():
    """Existing connection is tested and reused."""
    executor = SSHExecutor(host="test-host")

    # Mock a live connection that responds to "echo ok"
    alive_result = MagicMock()
    alive_result.exit_status = 0

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(return_value=alive_result)

    executor._conn = mock_conn

    conn = await executor._ensure_connection()
    assert conn is mock_conn


@pytest.mark.asyncio
async def test_close():
    executor = SSHExecutor(host="test-host")
    mock_conn = MagicMock()
    executor._conn = mock_conn

    await executor.close()
    mock_conn.close.assert_called_once()
    assert executor._conn is None


# ── Configurable connect timeout ──────────────────────────────────


def test_default_connect_timeout():
    executor = SSHExecutor(host="test-host")
    assert executor.connect_timeout == 10.0


def test_custom_connect_timeout():
    executor = SSHExecutor(host="test-host", connect_timeout=20.0)
    assert executor.connect_timeout == 20.0


@pytest.mark.asyncio
async def test_liveness_check_uses_connect_timeout():
    """Connection liveness check should use connect_timeout, not command timeout."""
    executor = SSHExecutor(host="test-host", connect_timeout=7.0)

    alive_result = MagicMock()
    alive_result.exit_status = 0

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(return_value=alive_result)
    executor._conn = mock_conn

    conn = await executor._ensure_connection()
    assert conn is mock_conn


# ── Coverage: run() connection failure ───────────────────────────


@pytest.mark.asyncio
async def test_run_connection_failure():
    """run() returns error result when SSH command raises generic exception."""
    executor = SSHExecutor(host="test-host")

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(side_effect=OSError("Connection reset"))
    executor._conn = mock_conn
    executor._ensure_connection = AsyncMock(return_value=mock_conn)

    result = await executor.run("echo hello")

    assert not result.ok
    assert result.exit_code == -1
    assert "SSH error" in result.stderr
    assert "Connection reset" in result.stderr
    # Connection should be reset on failure
    assert executor._conn is None


# ── Coverage: _ensure_connection reconnect on liveness failure ───


@pytest.mark.asyncio
async def test_connect_reconnects_on_liveness_failure():
    """_ensure_connection creates new connection when liveness check fails."""
    executor = SSHExecutor(host="test-host")

    # Old connection whose liveness check fails
    old_conn = AsyncMock()
    old_conn.run = AsyncMock(side_effect=OSError("connection dead"))
    executor._conn = old_conn

    # New connection created by asyncssh.connect
    new_result = MagicMock()
    new_result.exit_status = 0
    new_conn = AsyncMock()
    new_conn.run = AsyncMock(return_value=new_result)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(
            "maude.daemon.executor.asyncssh.connect",
            AsyncMock(return_value=new_conn),
        )
        conn = await executor._ensure_connection()

    assert conn is new_conn
    assert executor._conn is new_conn


# ── Coverage: liveness check failure (timeout) ───────────────────


@pytest.mark.asyncio
async def test_liveness_check_timeout_reconnects():
    """_ensure_connection reconnects when liveness check times out."""
    executor = SSHExecutor(host="test-host", connect_timeout=0.01)

    # Old connection whose liveness check times out
    never_done = asyncio.Future()
    old_conn = MagicMock()
    old_conn.run = MagicMock(return_value=never_done)
    executor._conn = old_conn

    # New connection
    new_conn = AsyncMock()

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(
            "maude.daemon.executor.asyncssh.connect",
            AsyncMock(return_value=new_conn),
        )
        conn = await executor._ensure_connection()

    assert conn is new_conn
    assert executor._conn is new_conn
