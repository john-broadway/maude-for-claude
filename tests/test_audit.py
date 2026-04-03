# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.audit — audit logger and entry formatting."""

import json
from unittest.mock import AsyncMock

import pytest

from maude.memory.audit import AuditEntry, AuditLogger, elapsed, timed

# ── AuditEntry ───────────────────────────────────────────────────────


def test_audit_entry_to_dict():
    entry = AuditEntry(
        project="monitoring",
        tool="service_status",
        caller="claude-code",
        params={"lines": 50},
        result_summary="ok",
        success=True,
        duration_ms=12.5,
        reason="checking",
    )
    d = entry.to_dict()
    assert d["project"] == "monitoring"
    assert d["tool"] == "service_status"
    assert d["success"] is True
    assert d["duration_ms"] == 12.5
    assert d["reason"] == "checking"
    assert d["caller_role"] == ""
    assert d["access_decision"] == ""


def test_audit_entry_with_acl_fields():
    entry = AuditEntry(
        project="my-service",
        tool="service_restart",
        caller="monitoring",
        params={},
        result_summary="denied",
        success=False,
        duration_ms=0.5,
        caller_role="viewer",
        access_decision="denied",
    )
    d = entry.to_dict()
    assert d["caller_role"] == "viewer"
    assert d["access_decision"] == "denied"
    j = entry.to_json()
    data = json.loads(j)
    assert data["caller_role"] == "viewer"
    assert data["access_decision"] == "denied"


def test_audit_entry_to_json():
    entry = AuditEntry(
        project="my-service",
        tool="service_restart",
        caller="test",
        params={},
        result_summary="restarted",
        success=True,
        duration_ms=100.0,
    )
    j = entry.to_json()
    data = json.loads(j)
    assert data["project"] == "my-service"
    assert "timestamp" in data


def test_audit_entry_truncates_in_log():
    """log() truncates result_summary to 1000 chars."""
    long_result = "x" * 2000
    entry = AuditEntry(
        project="test",
        tool="test_tool",
        caller="test",
        params={},
        result_summary=long_result,
        success=True,
        duration_ms=1.0,
    )
    # The AuditLogger.log() truncates at pool.execute time
    # Verify the entry itself stores the full value
    assert len(entry.result_summary) == 2000


def test_log_tool_call_truncates_result():
    """log_tool_call convenience method truncates to 500 chars."""
    # Verified by reading the source — result[:500] in log_tool_call
    entry = AuditEntry(
        project="test",
        tool="t",
        caller="c",
        params={},
        result_summary="x" * 600,
        success=True,
        duration_ms=1.0,
    )
    # AuditEntry stores what's passed — truncation happens in log_tool_call
    assert len(entry.result_summary) == 600


# ── AuditLogger ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_log_without_pool_falls_back_to_stdout(caplog):
    """When DB connection fails, audit still logs to stdout."""
    logger = AuditLogger(project="test", db_host="127.0.0.1")
    # Mock _ensure_pool to raise
    logger._ensure_pool = AsyncMock(side_effect=ConnectionRefusedError("no db"))  # type: ignore[method-assign]

    entry = AuditEntry(
        project="test",
        tool="test_tool",
        caller="test",
        params={},
        result_summary="ok",
        success=True,
        duration_ms=1.0,
    )
    with caplog.at_level("INFO"):
        await logger.log(entry)

    # Should have logged to stdout despite DB failure
    assert any("AUDIT:" in r.message for r in caplog.records)


# ── timed / elapsed ─────────────────────────────────────────────────


def test_timed_returns_float():
    start = timed()
    assert isinstance(start, float)


def test_elapsed_returns_positive():
    import time

    start = timed()
    time.sleep(0.01)
    ms = elapsed(start)
    assert ms > 0
    assert ms < 1000  # Should be ~10ms, not seconds


# ── Coverage: _ensure_pool ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_lazy_pool_creates_on_first_get():
    """LazyPool creates an asyncpg pool on first call."""
    from unittest.mock import patch

    mock_pool = AsyncMock()

    with (
        patch("maude.db.pool.pg_pool_kwargs", return_value={
            "host": "localhost", "port": 5432, "user": "support",
            "password": "secret", "database": "agent", "min_size": 1, "max_size": 3,
        }),
        patch(
            "maude.db.pool.asyncpg.create_pool",
            new_callable=AsyncMock, return_value=mock_pool,
        ) as mock_create,
    ):
        logger_inst = AuditLogger(project="test", db_host="localhost")
        pool = await logger_inst._db.get()

    assert pool is mock_pool
    mock_create.assert_awaited_once()


@pytest.mark.asyncio
async def test_lazy_pool_reuses_existing():
    """LazyPool returns existing pool without creating a new one."""
    from unittest.mock import patch

    existing_pool = AsyncMock()
    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst._db._pool = existing_pool

    with patch(
        "maude.db.pool.asyncpg.create_pool", new_callable=AsyncMock,
    ) as mock_create:
        pool = await logger_inst._db.get()

    assert pool is existing_pool
    mock_create.assert_not_awaited()


# ── Coverage: log() successful write ────────────────────────────────


@pytest.mark.asyncio
async def test_log_writes_to_pool():
    """log() writes audit entry to PostgreSQL via pool.execute."""
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock()

    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst._db.get = AsyncMock(return_value=mock_pool)  # type: ignore[method-assign]

    entry = AuditEntry(
        project="test",
        tool="service_status",
        caller="claude-code",
        params={"lines": 10},
        result_summary="ok",
        success=True,
        duration_ms=5.0,
    )

    await logger_inst.log(entry)
    mock_pool.execute.assert_awaited_once()
    call_args = mock_pool.execute.call_args[0]
    assert call_args[1] == "test"  # project
    assert call_args[2] == "service_status"  # tool
    assert call_args[3] == "claude-code"  # caller


# ── Coverage: log_tool_call ─────────────────────────────────────────


@pytest.mark.asyncio
async def test_log_tool_call_creates_entry_and_logs():
    """log_tool_call creates an AuditEntry and calls log()."""
    logger_inst = AuditLogger(project="monitoring", db_host="localhost")
    logger_inst.log = AsyncMock()  # type: ignore[method-assign]

    await logger_inst.log_tool_call(
        tool="monitoring_health",
        caller="claude-code",
        params={"verbose": True},
        result="healthy",
        success=True,
        duration_ms=42.0,
        reason="scheduled check",
    )

    logger_inst.log.assert_awaited_once()
    entry = logger_inst.log.call_args[0][0]
    assert isinstance(entry, AuditEntry)
    assert entry.project == "monitoring"
    assert entry.tool == "monitoring_health"
    assert entry.reason == "scheduled check"
    assert entry.result_summary == "healthy"


@pytest.mark.asyncio
async def test_log_tool_call_truncates_result_async():
    """log_tool_call truncates result to 500 chars."""
    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst.log = AsyncMock()  # type: ignore[method-assign]

    await logger_inst.log_tool_call(
        tool="t",
        caller="c",
        params={},
        result="x" * 1000,
        success=True,
        duration_ms=1.0,
    )

    entry = logger_inst.log.call_args[0][0]
    assert len(entry.result_summary) == 500


# ── Coverage: close() ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_close_closes_pool():
    """close() closes the pool and sets it to None."""
    mock_pool = AsyncMock()
    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst._db._pool = mock_pool

    await logger_inst.close()

    mock_pool.close.assert_awaited_once()
    assert logger_inst._db._pool is None


@pytest.mark.asyncio
async def test_log_tool_call_with_acl_fields():
    """log_tool_call passes caller_role and access_decision to AuditEntry."""
    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst.log = AsyncMock()  # type: ignore[method-assign]

    await logger_inst.log_tool_call(
        tool="service_restart",
        caller="monitoring",
        params={},
        result="denied",
        success=False,
        duration_ms=0.5,
        caller_role="viewer",
        access_decision="denied",
    )

    entry = logger_inst.log.call_args[0][0]
    assert entry.caller_role == "viewer"
    assert entry.access_decision == "denied"


@pytest.mark.asyncio
async def test_log_writes_acl_fields_to_pool():
    """log() passes caller_role and access_decision as positional args to pool.execute."""
    mock_pool = AsyncMock()
    mock_pool.execute = AsyncMock()

    logger_inst = AuditLogger(project="test", db_host="localhost")
    logger_inst._db.get = AsyncMock(return_value=mock_pool)  # type: ignore[method-assign]

    entry = AuditEntry(
        project="test",
        tool="service_restart",
        caller="monitoring",
        params={},
        result_summary="denied",
        success=False,
        duration_ms=0.5,
        caller_role="viewer",
        access_decision="denied",
    )

    await logger_inst.log(entry)
    call_args = mock_pool.execute.call_args[0]
    # Args: SQL, project, tool, caller, params, result, success,
    # duration, reason, caller_role, access_decision
    assert call_args[9] == "viewer"  # caller_role
    assert call_args[10] == "denied"  # access_decision


@pytest.mark.asyncio
async def test_close_when_no_pool():
    """close() is safe when no pool exists."""
    logger_inst = AuditLogger(project="test", db_host="localhost")
    assert logger_inst._db._pool is None

    await logger_inst.close()  # Should not raise
    assert logger_inst._db._pool is None
