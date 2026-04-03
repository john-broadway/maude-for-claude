# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.local_executor — subprocess command runner."""


import pytest

from maude.daemon.executor import LocalExecutor


@pytest.mark.asyncio
async def test_run_success():
    executor = LocalExecutor()
    result = await executor.run("echo hello")
    assert result.ok
    assert result.stdout == "hello"
    assert result.exit_code == 0


@pytest.mark.asyncio
async def test_run_failure():
    executor = LocalExecutor()
    result = await executor.run("false")
    assert not result.ok
    assert result.exit_code != 0


@pytest.mark.asyncio
async def test_run_timeout():
    executor = LocalExecutor(timeout=0.1)
    result = await executor.run("sleep 10", timeout=0.1)
    assert not result.ok
    assert result.exit_code == -1
    assert "timed out" in result.stderr


@pytest.mark.asyncio
async def test_run_captures_stderr():
    executor = LocalExecutor()
    result = await executor.run("echo err >&2")
    assert result.stderr == "err"


@pytest.mark.asyncio
async def test_close_noop():
    executor = LocalExecutor()
    await executor.close()  # Should not raise
