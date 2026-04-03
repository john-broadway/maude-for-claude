# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Shared test utilities for Maude consumer rooms.

Provides fake implementations of core Maude components for use in
pytest test suites. Import these instead of duplicating per-project.

Usage::

    from maude.testing import (
        FakeExecutor, FakeSSHResult, FakeAudit, FakeKillSwitch, FakeMCP, FakeRedis,
        FakeTrainingLoop, FakeRelayOutbox,
    )
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class FakeSSHResult:
    """Mimics daemon.executor.SSHResult for tests."""

    stdout: str = ""
    stderr: str = ""
    exit_code: int = 0

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


class FakeExecutor:
    """Mock SSH/Local executor with pattern-matched canned responses."""

    def __init__(self, responses: dict[str, FakeSSHResult] | None = None) -> None:
        self._responses = responses or {}
        self._default = FakeSSHResult()
        self.calls: list[str] = []

    async def run(self, cmd: str) -> FakeSSHResult:
        self.calls.append(cmd)
        for pattern, result in self._responses.items():
            if pattern in cmd:
                return result
        return self._default

    async def close(self) -> None:
        pass


class FakeAudit:
    """No-op audit logger for tests."""

    async def log_tool_call(self, **kwargs: Any) -> None:
        pass

    async def close(self) -> None:
        pass


class FakeKillSwitch:
    """Controllable kill switch for tests."""

    def __init__(
        self,
        *,
        active: bool = False,
        project: str = "test",
        reason: str = "",
    ) -> None:
        self._active = active
        self._project = project
        self._reason = reason

    @property
    def active(self) -> bool:
        return self._active

    def check_or_raise(self) -> None:
        if self._active:
            raise PermissionError("Kill switch is active for test")

    def status(self) -> dict[str, Any]:
        return {
            "project": self._project,
            "active": self._active,
            "reason": self._reason,
            "flag_path": f"/tmp/maude-{self._project}-kill",
        }

    def activate(self, reason: str = "") -> None:
        self._active = True
        self._reason = reason

    def deactivate(self) -> None:
        self._active = False
        self._reason = ""


class FakeMCP:
    """Collects registered tools and resources for testing."""

    def __init__(self) -> None:
        self.tools: dict[str, Any] = {}
        self.resources: dict[str, Any] = {}

    def tool(self) -> Any:
        def decorator(func: Any) -> Any:
            self.tools[func.__name__] = func
            return func

        return decorator

    def resource(self, uri: str, **kwargs: Any) -> Any:
        """Register an MCP resource by URI."""

        def decorator(func: Any) -> Any:
            self.resources[uri] = {"fn": func, "uri": uri, **kwargs}
            return func

        return decorator


class FakeRedis:
    """In-memory Redis mock for tests.

    Mirrors the MaudeRedis API surface so tests can run without
    a real Redis connection.
    """

    def __init__(self) -> None:
        self._store: dict[str, str] = {}
        self._streams: dict[str, list[tuple[str, dict[str, Any]]]] = {}
        self._stream_counter = 0

    async def connect(self) -> bool:
        return True

    async def close(self) -> None:
        pass

    @property
    def available(self) -> bool:
        return True

    async def get(self, key: str) -> str | None:
        return self._store.get(key)

    async def set(self, key: str, value: str, ttl: int | None = None) -> bool:
        self._store[key] = value
        return True

    async def delete(self, key: str) -> bool:
        self._store.pop(key, None)
        return True

    async def rate_check(self, key: str, limit: int, window: int) -> dict[str, Any]:
        return {"allowed": True, "remaining": 0}

    async def publish_event(self, stream: str, data: dict[str, Any]) -> str | None:
        self._stream_counter += 1
        entry_id = f"0-{self._stream_counter}"
        self._streams.setdefault(stream, []).append((entry_id, data))
        return entry_id

    async def read_events(
        self, stream: str, last_id: str = "$", count: int = 10, block: int = 0
    ) -> list[dict[str, Any]]:
        entries = self._streams.get(stream, [])
        return [{"id": eid, **fields} for eid, fields in entries[-count:]]

    async def broadcast(self, channel: str, message: str) -> int:
        return 1


class FakeTrainingLoop:
    """No-op training loop for consumer tests."""

    def __init__(self) -> None:
        self._current_stage = "idle"

    async def start(self) -> None:
        pass

    async def stop(self) -> None:
        pass

    def current_status(self) -> dict[str, Any]:
        return {"enabled": False, "stage": "idle"}

    async def training_history(self, limit: int = 10) -> list[dict[str, Any]]:
        return []

    async def trigger_manual(self) -> dict[str, Any]:
        return {"status": "disabled"}


class FakeLocalStore:
    """In-memory LocalStore mock for tests.

    Mirrors the LocalStore API surface so tests can run without SQLite.
    """

    def __init__(self) -> None:
        self._memories: list[dict[str, Any]] = []
        self._id_counter = 0

    async def initialize(self) -> None:
        pass

    async def store(self, **kwargs: Any) -> int:
        self._id_counter += 1
        kwargs["id"] = self._id_counter
        kwargs.setdefault("created_at", "2026-01-01T00:00:00")
        self._memories.append(kwargs)
        return self._id_counter

    async def recall_recent(
        self,
        memory_type: str | None = None,
        limit: int = 10,
    ) -> list[dict[str, Any]]:
        filtered = self._memories
        if memory_type:
            filtered = [m for m in filtered if m.get("memory_type") == memory_type]
        return list(reversed(filtered[-limit:]))

    async def recall_by_id(self, memory_id: int) -> dict[str, Any] | None:
        for m in self._memories:
            if m.get("id") == memory_id:
                return m
        return None

    async def search_fts(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        return []

    async def detect_patterns(
        self,
        threshold: int = 3,
        window_days: int = 7,
    ) -> list[dict[str, Any]]:
        return []

    async def find_past_fix(
        self,
        root_cause: str,
        summary: str = "",
    ) -> str | None:
        return None

    async def get_pending_sync(self, limit: int = 50) -> list[dict[str, Any]]:
        return []

    async def enqueue_sync(self, memory_id: int, target_tier: int) -> None:
        pass

    async def mark_synced(
        self,
        memory_id: int,
        target_tier: int,
        *,
        pg_id: int | None = None,
    ) -> None:
        pass

    async def mark_sync_failed(self, memory_id: int, target_tier: int) -> None:
        pass

    async def warm_from_pg(self, rows: list[dict[str, Any]]) -> int:
        return 0

    async def audit_log(
        self,
        tool: str,
        action: str,
        detail: str = "",
        caller: str = "",
    ) -> None:
        pass

    async def stats(self) -> dict[str, Any]:
        return {"total_memories": len(self._memories), "pending_sync": 0}

    async def close(self) -> None:
        pass


class FakeAdminRegistry:
    """Controllable admin registry for tests."""

    def __init__(
        self,
        *,
        enabled: bool = False,
        allowed_actions: set[str] | None = None,
    ) -> None:
        self._enabled = enabled
        self._allowed = allowed_actions or set()

    @property
    def enabled(self) -> bool:
        return self._enabled

    def is_allowed(self, action_name: str) -> bool:
        return self._enabled and action_name in self._allowed

    def check_guardrails(self, action_name: str, command: str = "") -> Any:
        """Returns an object with .allowed, .guardrail, .reason attributes."""

        class _Result:
            def __init__(self, allowed: bool, reason: str = "") -> None:
                self.allowed = allowed
                self.guardrail = "" if allowed else "not_allowed"
                self.reason = reason

        if not self._enabled or action_name not in self._allowed:
            return _Result(False, "not allowed")
        return _Result(True)

    def should_auto_resolve(
        self,
        action_name: str,
        success_rate: float,
        occurrences: int,
    ) -> bool:
        return self._enabled and action_name in self._allowed

    def describe(self) -> dict[str, Any]:
        return {"enabled": self._enabled, "allowed_actions": sorted(self._allowed)}


class FakeRelay:
    """In-memory relay mock for tests.

    Mirrors the Relay API surface so tests can run without PostgreSQL.
    """

    def __init__(self) -> None:
        self._tasks: list[dict[str, Any]] = []
        self._id_counter = 0

    async def send(
        self,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int:
        self._id_counter += 1
        self._tasks.append(
            {
                "id": self._id_counter,
                "from_room": from_room,
                "to_room": to_room,
                "subject": subject,
                "body": body,
                "status": "pending",
                "result": None,
                "priority": priority,
                "created_at": "2026-01-01T00:00:00+00:00",
                "updated_at": "2026-01-01T00:00:00+00:00",
                "accepted_at": None,
                "completed_at": None,
            }
        )
        return self._id_counter

    async def send_lenient(
        self,
        from_room: str,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int | None:
        try:
            return await self.send(from_room, to_room, subject, body, priority)
        except Exception:
            return None

    async def accept(self, task_id: int, room: str) -> Any:
        from datetime import datetime, timezone

        from maude.coordination.relay import RelayTask, TaskStatus

        for t in self._tasks:
            if t["id"] == task_id:
                t["status"] = "accepted"
                now = datetime.now(timezone.utc)
                return RelayTask(
                    id=t["id"],
                    from_room=t["from_room"],
                    to_room=t["to_room"],
                    subject=t["subject"],
                    body=t["body"],
                    status=TaskStatus.ACCEPTED,
                    result=t["result"],
                    priority=t["priority"],
                    created_at=now,
                    updated_at=now,
                    accepted_at=now,
                    completed_at=None,
                )
        raise ValueError(f"Task {task_id} not found")

    async def update(
        self,
        task_id: int,
        room: str,
        status: str,
        result: str = "",
    ) -> Any:
        from datetime import datetime, timezone

        from maude.coordination.relay import RelayTask, TaskStatus

        for t in self._tasks:
            if t["id"] == task_id:
                t["status"] = status
                t["result"] = result
                now = datetime.now(timezone.utc)
                target = TaskStatus(status)
                completed = now if status in ("completed", "failed", "cancelled") else None
                return RelayTask(
                    id=t["id"],
                    from_room=t["from_room"],
                    to_room=t["to_room"],
                    subject=t["subject"],
                    body=t["body"],
                    status=target,
                    result=result or t["result"],
                    priority=t["priority"],
                    created_at=now,
                    updated_at=now,
                    accepted_at=None,
                    completed_at=completed,
                )
        raise ValueError(f"Task {task_id} not found")

    async def get(self, task_id: int) -> dict[str, Any] | None:
        for t in self._tasks:
            if t["id"] == task_id:
                return t
        return None

    async def tasks(
        self,
        room: str = "",
        status: str = "",
        from_room: str = "",
        limit: int = 20,
        since_minutes: int = 0,
    ) -> list[dict[str, Any]]:
        result = list(self._tasks)
        if room:
            result = [t for t in result if t["to_room"] == room]
        if status:
            result = [t for t in result if t["status"] == status]
        if from_room:
            result = [t for t in result if t["from_room"] == from_room]
        return list(reversed(result[-limit:]))

    async def inbox(
        self,
        room: str,
        limit: int = 20,
        since_minutes: int = 60,
    ) -> list[dict[str, Any]]:
        result = await self.tasks(room=room, limit=limit)
        return [
            {
                "id": t["id"],
                "body": t["body"],
                "from_room": t["from_room"],
                "to_room": t["to_room"],
                "subject": t["subject"],
                "status": t["status"],
                "ts": t["created_at"],
            }
            for t in result
        ]

    async def sweep_stale(self) -> list[int]:
        return []

    async def close(self) -> None:
        pass


class FakeRelayOutbox:
    """In-memory relay outbox mock for tests.

    Mirrors the RelayOutbox API surface so tests can run without SQLite.
    """

    def __init__(self) -> None:
        self._entries: list[dict[str, Any]] = []
        self._id_counter = 0
        self.project = "test"

    async def enqueue(
        self,
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> int:
        self._id_counter += 1
        self._entries.append(
            {
                "id": self._id_counter,
                "to_room": to_room,
                "subject": subject,
                "body": body,
                "priority": priority,
                "status": "pending",
                "pg_task_id": None,
                "attempts": 0,
                "last_attempt": None,
                "created_at": "2026-01-01T00:00:00",
            }
        )
        return self._id_counter

    async def pending(self, limit: int = 20) -> list[dict[str, Any]]:
        return [e for e in self._entries if e["status"] == "pending" and e["attempts"] < 10][:limit]

    async def mark_synced(self, outbox_id: int, pg_task_id: int | None = None) -> None:
        for e in self._entries:
            if e["id"] == outbox_id:
                e["status"] = "synced"
                e["pg_task_id"] = pg_task_id
                break

    async def mark_failed(self, outbox_id: int) -> None:
        for e in self._entries:
            if e["id"] == outbox_id:
                e["status"] = "failed"
                break

    async def increment_attempt(self, outbox_id: int) -> None:
        for e in self._entries:
            if e["id"] == outbox_id:
                e["attempts"] += 1
                if e["attempts"] >= 10:
                    e["status"] = "failed"
                break

    async def stats(self) -> dict[str, Any]:
        pending = sum(1 for e in self._entries if e["status"] == "pending")
        synced = sum(1 for e in self._entries if e["status"] == "synced")
        failed = sum(1 for e in self._entries if e["status"] == "failed")
        return {"pending": pending, "synced": synced, "failed": failed}


def reset_rate_limits() -> None:
    """Clear daemon.guards rate-limit state between tests.

    Uses both in-place clear AND module-level reassignment to ensure
    all references see the empty state — including closures created
    by @rate_limited decorators in different test module scopes.
    """
    import maude.daemon.guards as guards

    guards._rate_limit_state.clear()
    guards._rate_limit_state = {}
    guards._rate_limit_locks.clear()
    guards._rate_limit_locks = {}
    guards._redis_client = None
