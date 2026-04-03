# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Structured audit logger for MCP tool calls.

Every tool invocation is logged to PostgreSQL (agent_audit_log table)
and to stdout (picked up by Loki via Promtail).
"""

import asyncio
import contextvars
import json
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from maude.daemon.common import resolve_db_host

try:
    from maude.db import LazyPool
except ImportError:
    LazyPool = None  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)

# Context variable for caller attribution across async call boundaries.
# Set by ToolRegistry before calling a tool so @audit_logged picks up the
# correct caller identity without needing kwargs to survive FastMCP dispatch.
active_caller: contextvars.ContextVar[str] = contextvars.ContextVar(
    "active_caller",
    default="",
)


@dataclass
class AuditEntry:
    """A single audit log entry."""

    project: str
    tool: str
    caller: str
    params: dict[str, Any]
    result_summary: str
    success: bool
    duration_ms: float
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    reason: str = ""
    caller_role: str = ""
    access_decision: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "project": self.project,
            "tool": self.tool,
            "caller": self.caller,
            "params": self.params,
            "result_summary": self.result_summary,
            "success": self.success,
            "duration_ms": self.duration_ms,
            "timestamp": self.timestamp.isoformat(),
            "reason": self.reason,
            "caller_role": self.caller_role,
            "access_decision": self.access_decision,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), default=str)


class AuditLogger:
    """Log MCP tool calls to PostgreSQL and stdout.

    Args:
        project: Project identifier (e.g., "my-service", "monitoring").
        database: PostgreSQL database name. Defaults to "agent".
    """

    INSERT_SQL = """
        INSERT INTO agent_audit_log
            (project, tool, caller, params, result_summary, success,
             duration_ms, reason, caller_role, access_decision)
        VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, $9, $10)
    """

    def __init__(
        self,
        project: str,
        database: str = "agent",
        db_host: str = "",
    ) -> None:
        self.project = project
        self.database = database
        self.db_host = db_host or resolve_db_host()
        self._db = (
            LazyPool(database=database, db_host=self.db_host, suppress_errors=False)
            if LazyPool is not None
            else None
        )

    async def log(self, entry: AuditEntry) -> None:
        """Write an audit entry to PostgreSQL and stdout."""
        # Always log to stdout (Loki picks this up)
        logger.info("AUDIT: %s", entry.to_json())

        # Write to PostgreSQL (best-effort; stdout is the authoritative log)
        if self._db is None:
            return  # stdout-only mode — asyncpg not installed
        try:
            pool = await self._db.get()
            if pool is None:
                logger.error("Audit write skipped: database pool unavailable")
                return
            await asyncio.wait_for(
                pool.execute(
                    self.INSERT_SQL,
                    entry.project,
                    entry.tool,
                    entry.caller,
                    json.dumps(entry.params, default=str),
                    entry.result_summary[:1000],  # Truncate large results
                    entry.success,
                    entry.duration_ms,
                    entry.reason,
                    entry.caller_role,
                    entry.access_decision,
                ),
                timeout=5.0,
            )
        except Exception as e:
            # Audit failure must not break tool execution
            logger.error("Audit write failed: %s", e)

    async def log_tool_call(
        self,
        tool: str,
        caller: str,
        params: dict[str, Any],
        result: str,
        success: bool,
        duration_ms: float,
        reason: str = "",
        caller_role: str = "",
        access_decision: str = "",
    ) -> None:
        """Convenience method to log a tool call."""
        entry = AuditEntry(
            project=self.project,
            tool=tool,
            caller=caller,
            params=params,
            result_summary=result[:500],
            success=success,
            duration_ms=duration_ms,
            reason=reason,
            caller_role=caller_role,
            access_decision=access_decision,
        )
        await self.log(entry)

    async def close(self) -> None:
        """Close the database pool."""
        if self._db is not None:
            await self._db.close()


def timed() -> float:
    """Return a timer start value. Use with elapsed()."""
    return time.monotonic()


def elapsed(start: float) -> float:
    """Return milliseconds elapsed since start."""
    return (time.monotonic() - start) * 1000
