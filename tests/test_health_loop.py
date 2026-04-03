# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for health loop — escalation callback and rate limiting."""

import asyncio
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.healing.health_checks import (
    CredentialProbe,
    HealthLoopConfig,
    HealthStatus,
    _status_to_context,
)
from maude.healing.health_loop import HealthLoop


@pytest.fixture
def health_loop(mock_audit: AsyncMock, mock_executor: AsyncMock) -> HealthLoop:
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        max_restart_attempts=3,
        cooldown_seconds=600,
    )
    return HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )


# ── HealthLoopConfig ────────────────────────────────────────────────


def test_config_from_dict():
    data = {"enabled": True, "interval_seconds": 120, "heartbeat_url": "http://kuma/push/1"}
    config = HealthLoopConfig.from_dict(data)
    assert config.enabled is True
    assert config.interval_seconds == 120
    assert config.heartbeat_url == "http://kuma/push/1"


def test_config_from_none():
    config = HealthLoopConfig.from_dict(None)
    assert config.enabled is False
    assert config.interval_seconds == 300


# ── _status_to_context ──────────────────────────────────────────────


def test_status_to_context():
    status = HealthStatus(
        service_active=True,
        memory_percent=45,
        disk_percent=60,
        healthy=True,
        action="none",
        reason="All clear",
    )
    ctx = _status_to_context(status)
    assert ctx["service_active"] is True
    assert ctx["memory_percent"] == 45
    assert ctx["action"] == "none"


# ── Rate limiting ───────────────────────────────────────────────────


def test_can_restart_initially(health_loop: HealthLoop):
    assert health_loop._can_restart() is True


def test_can_restart_respects_cooldown(health_loop: HealthLoop):
    health_loop._restart_times = [time.monotonic()]
    assert health_loop._can_restart() is False


def test_can_restart_after_cooldown(health_loop: HealthLoop):
    health_loop._restart_times = [time.monotonic() - 700]  # Past 600s cooldown
    assert health_loop._can_restart() is True


def test_can_restart_respects_max_attempts(health_loop: HealthLoop):
    now = time.monotonic()
    # 3 restarts in the last hour, all past cooldown
    health_loop._restart_times = [now - 2000, now - 1500, now - 700]
    assert health_loop._can_restart() is False


def test_can_restart_prunes_old_entries(health_loop: HealthLoop):
    now = time.monotonic()
    # 3 restarts but 2 are older than 1 hour
    health_loop._restart_times = [now - 4000, now - 3800, now - 700]
    assert health_loop._can_restart() is True


# ── Escalation callback ────────────────────────────────────────────


async def test_escalation_callback_called(health_loop: HealthLoop):
    callback = AsyncMock()
    health_loop.set_escalation_callback(callback)

    await health_loop._escalate("test_trigger", {"key": "value"})

    callback.assert_called_once_with("test_trigger", {"key": "value"})


async def test_escalation_no_callback_is_noop(health_loop: HealthLoop):
    # No exception, just logs
    await health_loop._escalate("test_trigger", {})


async def test_escalation_callback_failure_is_nonfatal(health_loop: HealthLoop):
    callback = AsyncMock(side_effect=Exception("callback crashed"))
    health_loop.set_escalation_callback(callback)

    # Should not raise
    await health_loop._escalate("test_trigger", {})


# ── _act with escalation ───────────────────────────────────────────


async def test_act_restart_blocked_by_kill_switch(health_loop: HealthLoop):
    status = HealthStatus(action="restart", reason="Service down", kill_switch_active=True)

    with patch.object(health_loop, "_audit_action", new=AsyncMock()) as mock_audit:
        await health_loop._act(status)

    mock_audit.assert_called_once()
    assert "kill_switch" in mock_audit.call_args[0][0]


async def test_act_escalate_calls_callback(health_loop: HealthLoop):
    callback = AsyncMock()
    health_loop.set_escalation_callback(callback)

    status = HealthStatus(
        action="escalate",
        reason="Disk high: 85%",
        disk_percent=85,
    )

    with patch.object(health_loop, "_audit_action", new=AsyncMock()):
        await health_loop._act(status)

    callback.assert_called_once()
    trigger = callback.call_args[0][0]
    assert "escalation" in trigger


async def test_act_rate_limited_restart_escalates(health_loop: HealthLoop):
    callback = AsyncMock()
    health_loop.set_escalation_callback(callback)

    # Exhaust restart attempts
    health_loop._restart_times = [time.monotonic()] * 3

    status = HealthStatus(action="restart", reason="Service down")

    with patch.object(health_loop, "_audit_action", new=AsyncMock()):
        await health_loop._act(status)

    callback.assert_called_once()
    trigger = callback.call_args[0][0]
    assert "rate_limited" in trigger


# ── SSL verification for HTTPS health endpoints ──────────────────


async def test_start_https_endpoint_disables_ssl_verify(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """httpx client should use verify=False when health endpoint is HTTPS."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        health_endpoint="https://localhost:8007/api2/json",
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="proxmox-backup-server",
        project="pbs",
        health_config=config,
    )
    await hl.start()
    try:
        assert hl._http is not None
        assert hl._http._transport._pool._ssl_context.verify_mode == 0  # CERT_NONE
    finally:
        await hl.stop()


async def test_start_http_endpoint_keeps_ssl_verify(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """httpx client should keep default verify=True for HTTP endpoints."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        health_endpoint="http://localhost:3000/api/health",
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )
    await hl.start()
    try:
        assert hl._http is not None
        # Default verify=True — no CERT_NONE
        assert hl._http._transport._pool._ssl_context.verify_mode != 0
    finally:
        await hl.stop()


# ── Configurable health endpoint timeout ─────────────────────────


def test_config_default_timeout():
    config = HealthLoopConfig()
    assert config.health_endpoint_timeout == 10


def test_config_custom_timeout():
    data = {"enabled": True, "health_endpoint_timeout": 30}
    config = HealthLoopConfig.from_dict(data)
    assert config.health_endpoint_timeout == 30


async def test_start_uses_configured_timeout(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """httpx client timeout should match the configured value."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        health_endpoint="http://localhost:3000/api/health",
        health_endpoint_timeout=25,
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )
    await hl.start()
    try:
        assert hl._http is not None
        assert hl._http.timeout.connect == 25.0
    finally:
        await hl.stop()


# ── Specific error messages in _check_health_endpoint ─────────────


async def test_check_health_endpoint_connect_timeout(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """ConnectTimeout should report 'connect timeout'."""
    import httpx

    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._http.get = AsyncMock(side_effect=httpx.ConnectTimeout("timed out"))
        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert detail == "connect timeout"
    finally:
        await hl.stop()


async def test_check_health_endpoint_read_timeout(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """ReadTimeout should report 'read timeout (endpoint slow)'."""
    import httpx

    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._http.get = AsyncMock(side_effect=httpx.ReadTimeout("slow"))
        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert "read timeout" in detail
    finally:
        await hl.stop()


async def test_check_health_endpoint_connect_error_with_cause(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """ConnectError should include the cause type in the message."""
    import httpx

    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        err = httpx.ConnectError("connection refused")
        err.__cause__ = ConnectionRefusedError("refused")
        hl._http.get = AsyncMock(side_effect=err)
        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert "ConnectionRefusedError" in detail
    finally:
        await hl.stop()


# ── Heartbeat failure tracking ────────────────────────────────────


async def test_heartbeat_resets_counter_on_success(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Successful heartbeat should reset the failure counter."""
    config = HealthLoopConfig(enabled=True, heartbeat_url="http://kuma/push/1")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._heartbeat_failures = 3
        mock_resp = AsyncMock()
        mock_resp.status_code = 200
        hl._http.get = AsyncMock(return_value=mock_resp)

        status = HealthStatus(healthy=True, reason="ok")
        await hl._heartbeat(status)
        assert hl._heartbeat_failures == 0
    finally:
        await hl.stop()


async def test_heartbeat_increments_counter_on_failure(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Failed heartbeat should increment the counter."""
    config = HealthLoopConfig(enabled=True, heartbeat_url="http://kuma/push/1")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._http.get = AsyncMock(side_effect=Exception("network down"))

        status = HealthStatus(healthy=True, reason="ok")
        await hl._heartbeat(status)
        assert hl._heartbeat_failures == 1
        await hl._heartbeat(status)
        assert hl._heartbeat_failures == 2
    finally:
        await hl.stop()


# ── set_domain_checks ─────────────────────────────────────────────


def test_set_domain_checks(health_loop: HealthLoop):
    """set_domain_checks stores the callback."""
    callback = AsyncMock()
    health_loop.set_domain_checks(callback)
    assert health_loop._domain_checks is callback


# ── start() when disabled ─────────────────────────────────────────


async def test_start_disabled_is_noop(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """start() with enabled=False should not create a task or HTTP client."""
    config = HealthLoopConfig(enabled=False)
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    assert hl._task is None
    assert hl._http is None


# ── _is_kill_switch_active ────────────────────────────────────────


def test_kill_switch_active_when_path_exists(health_loop: HealthLoop):
    """_is_kill_switch_active returns True when readonly file exists."""
    with patch("pathlib.Path.exists", return_value=True):
        assert health_loop._is_kill_switch_active() is True


def test_kill_switch_inactive_when_path_missing(health_loop: HealthLoop):
    """_is_kill_switch_active returns False when readonly file is absent."""
    with patch("pathlib.Path.exists", return_value=False):
        assert health_loop._is_kill_switch_active() is False


# ── _check_health_endpoint (no endpoint, HTTP success, non-200, JSON) ─


async def test_check_health_endpoint_no_endpoint(health_loop: HealthLoop):
    """Returns (True, '') when no health endpoint is configured."""
    health_loop.hc.health_endpoint = ""
    ok, detail = await health_loop._check_health_endpoint()
    assert ok is True
    assert detail == ""


async def test_check_health_endpoint_http_success_json(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """HTTP 200 with JSON body extracts status field."""
    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"status": "healthy"}
        hl._http.get = AsyncMock(return_value=mock_resp)

        ok, detail = await hl._check_health_endpoint()
        assert ok is True
        assert "healthy" in detail
    finally:
        await hl.stop()


async def test_check_health_endpoint_http_success_no_json(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """HTTP 200 with non-JSON body returns 'ok'."""
    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.side_effect = ValueError("not json")
        hl._http.get = AsyncMock(return_value=mock_resp)

        ok, detail = await hl._check_health_endpoint()
        assert ok is True
        assert detail == "ok"
    finally:
        await hl.stop()


async def test_check_health_endpoint_non_200(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Non-200 status code reports HTTP error."""
    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        mock_resp = MagicMock()
        mock_resp.status_code = 503
        hl._http.get = AsyncMock(return_value=mock_resp)

        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert detail == "HTTP 503"
    finally:
        await hl.stop()


async def test_check_health_endpoint_generic_timeout(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Generic TimeoutException reports 'timeout'."""
    import httpx

    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._http.get = AsyncMock(side_effect=httpx.TimeoutException("generic"))
        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert detail == "timeout"
    finally:
        await hl.stop()


async def test_check_health_endpoint_generic_exception(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Generic exception reports type name and message."""
    config = HealthLoopConfig(enabled=True, health_endpoint="http://localhost:3000/health")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._http.get = AsyncMock(side_effect=RuntimeError("boom"))
        ok, detail = await hl._check_health_endpoint()
        assert ok is False
        assert "RuntimeError" in detail
        assert "boom" in detail
    finally:
        await hl.stop()


# ── _run_domain_checks ────────────────────────────────────────────


async def test_run_domain_checks_no_callback(health_loop: HealthLoop):
    """Returns empty dict when no domain checks registered."""
    result = await health_loop._run_domain_checks()
    assert result == {}


async def test_run_domain_checks_success(health_loop: HealthLoop):
    """Calls callback and returns its result."""
    callback = AsyncMock(return_value={"alerts_firing": 3})
    health_loop.set_domain_checks(callback)
    result = await health_loop._run_domain_checks()
    assert result == {"alerts_firing": 3}
    callback.assert_called_once()


async def test_run_domain_checks_exception(health_loop: HealthLoop):
    """Exception in domain check returns error dict, does not raise."""
    callback = AsyncMock(side_effect=Exception("domain check boom"))
    health_loop.set_domain_checks(callback)
    result = await health_loop._run_domain_checks()
    assert "error" in result


# ── Helper to build executor side_effect for _check_health ────────


def _make_executor_responses(
    *,
    service_state: str = "active",
    memory_pct: str = "45",
    swap_pct: str = "0",
    disk_pct: str = "60",
    error_count: str = "3",
) -> list[MagicMock]:
    """Build 5 sequential mock results for _check_health's executor calls."""
    results = []
    for stdout, ok in [
        (f"{service_state}\n", True),
        (f"{memory_pct}\n", True),
        (f"{swap_pct}\n", True),
        (f"{disk_pct}\n", True),
        (f"{error_count}\n", True),
    ]:
        r = MagicMock()
        r.stdout = stdout
        r.ok = ok
        results.append(r)
    return results


# ── _check_health composite tests ─────────────────────────────────


async def test_check_health_all_clear(health_loop: HealthLoop):
    """All metrics normal returns healthy with action=none."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses())
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is True
    assert status.action == "none"
    assert status.service_active is True
    assert status.memory_percent == 45
    assert status.disk_percent == 60
    assert status.recent_errors == 3


async def test_check_health_service_inactive(health_loop: HealthLoop):
    """Inactive service triggers restart action."""
    health_loop.executor.run = AsyncMock(
        side_effect=_make_executor_responses(service_state="inactive")
    )
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "restart"
    assert "not active" in status.reason


async def test_check_health_kill_switch_recorded(health_loop: HealthLoop):
    """Kill switch active is recorded in status."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses())
    with patch.object(health_loop, "_is_kill_switch_active", return_value=True):
        status = await health_loop._check_health()

    assert status.kill_switch_active is True
    # Service is active and everything normal, so still healthy
    assert status.healthy is True


async def test_check_health_endpoint_unhealthy_triggers_restart(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Unhealthy endpoint triggers restart when no upstream issue."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        max_restart_attempts=3,
        cooldown_seconds=600,
        health_endpoint="http://localhost:3000/health",
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )
    hl.executor.run = AsyncMock(side_effect=_make_executor_responses())
    with (
        patch.object(hl, "_is_kill_switch_active", return_value=False),
        patch.object(hl, "_check_health_endpoint", return_value=(False, "HTTP 503")),
    ):
        status = await hl._check_health()

    assert status.healthy is False
    assert status.action == "restart"
    assert "endpoint unhealthy" in status.reason


async def test_check_health_upstream_issue_suppresses_restart(health_loop: HealthLoop):
    """Upstream issue from domain checks suppresses restart, action=warn_upstream."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses())
    domain_result = {"upstream_issue": True, "detail": "PostgreSQL down"}
    health_loop.set_domain_checks(AsyncMock(return_value=domain_result))

    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "warn_upstream"
    assert "PostgreSQL down" in status.reason


async def test_check_health_error_spike(health_loop: HealthLoop):
    """Error count > 10 triggers restart action."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses(error_count="15"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "restart"
    assert "Error spike" in status.reason


async def test_check_health_memory_critical(health_loop: HealthLoop):
    """Memory > 90% triggers restart action."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses(memory_pct="95"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "restart"
    assert "Memory critical" in status.reason


async def test_check_health_disk_high(health_loop: HealthLoop):
    """Disk > 80% triggers escalate action (restart won't help)."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses(disk_pct="85"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "escalate"
    assert "Disk high" in status.reason


async def test_check_health_endpoint_healthy_with_config(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Healthy endpoint sets endpoint_healthy=True."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        health_endpoint="http://localhost:3000/health",
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )
    hl.executor.run = AsyncMock(side_effect=_make_executor_responses())
    with (
        patch.object(hl, "_is_kill_switch_active", return_value=False),
        patch.object(hl, "_check_health_endpoint", return_value=(True, "ok (healthy)")),
    ):
        status = await hl._check_health()

    assert status.endpoint_healthy is True
    assert status.endpoint_detail == "ok (healthy)"
    assert status.healthy is True


# ── _publish_event ────────────────────────────────────────────────


async def test_publish_event_calls_publisher(health_loop: HealthLoop):
    """_publish_event calls the publisher when configured."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher
    await health_loop._publish_event("test_event", {"key": "val"})
    publisher.publish.assert_called_once_with("test_event", {"key": "val"})


async def test_publish_event_no_publisher(health_loop: HealthLoop):
    """_publish_event is a no-op without a publisher."""
    health_loop._event_publisher = None
    # Should not raise
    await health_loop._publish_event("test_event", {"key": "val"})


async def test_publish_event_exception_is_nonfatal(health_loop: HealthLoop):
    """Publisher exception does not propagate."""
    publisher = AsyncMock()
    publisher.publish.side_effect = Exception("publish failed")
    health_loop._event_publisher = publisher
    # Should not raise
    await health_loop._publish_event("test_event", {"key": "val"})


# ── _act: health status transition publishing ─────────────────────


async def test_act_publishes_transition_to_unhealthy(health_loop: HealthLoop):
    """Transition from healthy to unhealthy publishes event."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher
    health_loop._last_healthy = True

    status = HealthStatus(action="none", reason="All checks passed", healthy=False)
    # Force action to "none" but healthy=False to test the transition
    # without triggering restart logic
    status.action = "none"
    await health_loop._act(status)

    publisher.publish.assert_called_once()
    call_args = publisher.publish.call_args
    assert call_args[0][0] == "health_status_changed"
    assert call_args[0][1]["status"] == "unhealthy"


async def test_act_publishes_transition_to_healthy(health_loop: HealthLoop):
    """Transition from unhealthy to healthy publishes event."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher
    health_loop._last_healthy = False

    status = HealthStatus(action="none", reason="All checks passed", healthy=True)
    await health_loop._act(status)

    publisher.publish.assert_called_once()
    call_args = publisher.publish.call_args
    assert call_args[0][0] == "health_status_changed"
    assert call_args[0][1]["status"] == "healthy"


async def test_act_no_publish_when_no_transition(health_loop: HealthLoop):
    """No event published when status hasn't changed."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher
    health_loop._last_healthy = True

    status = HealthStatus(action="none", reason="All checks passed", healthy=True)
    await health_loop._act(status)

    publisher.publish.assert_not_called()


async def test_act_no_publish_on_first_check(health_loop: HealthLoop):
    """No event published on first check (_last_healthy is None)."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher
    assert health_loop._last_healthy is None

    status = HealthStatus(action="none", reason="All checks passed", healthy=True)
    await health_loop._act(status)

    publisher.publish.assert_not_called()
    assert health_loop._last_healthy is True


# ── _act: successful restart ──────────────────────────────────────


async def test_act_restart_success(health_loop: HealthLoop):
    """Successful restart records restart time and publishes event."""
    publisher = AsyncMock()
    health_loop._event_publisher = publisher

    restart_result = MagicMock()
    restart_result.ok = True
    health_loop.executor.run = AsyncMock(return_value=restart_result)

    status = HealthStatus(action="restart", reason="Service not active")
    health_loop._last_healthy = False  # prevent transition publish noise

    with patch.object(health_loop, "_audit_action", new=AsyncMock()) as mock_audit_action:
        await health_loop._act(status)

    # Restart time recorded
    assert len(health_loop._restart_times) == 1

    # Audit logged with success
    mock_audit_action.assert_called_once()
    assert mock_audit_action.call_args[0][0] == "auto_restart"
    assert mock_audit_action.call_args[0][3] is True  # success=True

    # Event published
    publish_calls = [c for c in publisher.publish.call_args_list if c[0][0] == "restart_performed"]
    assert len(publish_calls) == 1
    assert publish_calls[0][0][1]["success"] is True


async def test_act_restart_failure(health_loop: HealthLoop):
    """Failed restart still records the attempt and logs failure."""
    restart_result = MagicMock()
    restart_result.ok = False
    health_loop.executor.run = AsyncMock(return_value=restart_result)

    status = HealthStatus(action="restart", reason="Service not active")
    health_loop._last_healthy = False

    with patch.object(health_loop, "_audit_action", new=AsyncMock()) as mock_audit_action:
        await health_loop._act(status)

    assert len(health_loop._restart_times) == 1
    mock_audit_action.assert_called_once()
    assert mock_audit_action.call_args[0][3] is False  # success=False


# ── _act: warn_upstream path ──────────────────────────────────────


async def test_act_warn_upstream(health_loop: HealthLoop):
    """warn_upstream logs audit but does not restart."""
    health_loop._last_healthy = False

    status = HealthStatus(
        action="warn_upstream",
        reason="Upstream issue: PG down",
        healthy=False,
    )

    with patch.object(health_loop, "_audit_action", new=AsyncMock()) as mock_audit_action:
        await health_loop._act(status)

    mock_audit_action.assert_called_once()
    assert mock_audit_action.call_args[0][0] == "upstream_issue"
    # Executor should NOT have been called for restart
    health_loop.executor.run.assert_not_called()


# ── _act: none (healthy) path ─────────────────────────────────────


async def test_act_none_healthy(health_loop: HealthLoop):
    """Healthy action=none just logs debug, no audit."""
    health_loop._last_healthy = True

    status = HealthStatus(action="none", reason="All checks passed", healthy=True)

    with patch.object(health_loop, "_audit_action", new=AsyncMock()) as mock_audit_action:
        await health_loop._act(status)

    # No audit action for healthy status
    mock_audit_action.assert_not_called()


# ── _heartbeat edge cases ─────────────────────────────────────────


async def test_heartbeat_no_url(health_loop: HealthLoop):
    """_heartbeat returns immediately with no heartbeat URL."""
    health_loop.hc.heartbeat_url = ""
    status = HealthStatus(healthy=True, reason="ok")
    # Should not raise or make HTTP calls
    await health_loop._heartbeat(status)


async def test_heartbeat_non_200_increments_failure(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Non-200 heartbeat response increments failure counter."""
    config = HealthLoopConfig(enabled=True, heartbeat_url="http://kuma/push/1")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        mock_resp = MagicMock()
        mock_resp.status_code = 500
        hl._http.get = AsyncMock(return_value=mock_resp)

        status = HealthStatus(healthy=True, reason="ok")
        await hl._heartbeat(status)
        assert hl._heartbeat_failures == 1
    finally:
        await hl.stop()


async def test_heartbeat_failure_warning_at_5(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Heartbeat failure count >= 5 triggers warning log."""
    config = HealthLoopConfig(enabled=True, heartbeat_url="http://kuma/push/1")
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    await hl.start()
    try:
        hl._heartbeat_failures = 4  # Will become 5 after this failure
        hl._http.get = AsyncMock(side_effect=Exception("network down"))

        status = HealthStatus(healthy=True, reason="ok")
        with patch("maude.healing.health_loop.logger") as mock_logger:
            await hl._heartbeat(status)

        assert hl._heartbeat_failures == 5
        mock_logger.warning.assert_called_once()
        assert "5 consecutive" in mock_logger.warning.call_args[0][0] % (
            mock_logger.warning.call_args[0][1],
            mock_logger.warning.call_args[0][2],
        )
    finally:
        await hl.stop()


# ── _audit_action ─────────────────────────────────────────────────


async def test_audit_action_success(health_loop: HealthLoop):
    """_audit_action writes to audit log."""
    await health_loop._audit_action("auto_restart", "Service down", "restart succeeded", True)

    health_loop.audit.log_tool_call.assert_called_once()
    call_kwargs = health_loop.audit.log_tool_call.call_args[1]
    assert call_kwargs["tool"] == "health_loop.auto_restart"
    assert call_kwargs["caller"] == "concierge-staff"
    assert call_kwargs["success"] is True


async def test_audit_action_exception_is_nonfatal(health_loop: HealthLoop):
    """Exception in audit write does not propagate."""
    health_loop.audit.log_tool_call = AsyncMock(side_effect=Exception("DB down"))
    # Should not raise
    await health_loop._audit_action("auto_restart", "Service down", "restart failed", False)


# ── _loop main loop execution ─────────────────────────────────────


async def test_loop_runs_check_act_heartbeat(health_loop: HealthLoop):
    """_loop calls _check_health, _act, _heartbeat in sequence."""
    mock_status = HealthStatus(healthy=True, action="none", reason="ok")

    call_order: list[str] = []

    async def mock_check():
        call_order.append("check")
        return mock_status

    async def mock_act(status):
        call_order.append("act")

    async def mock_heartbeat(status):
        call_order.append("heartbeat")
        # Cancel after first iteration
        raise asyncio.CancelledError()

    with (
        patch.object(health_loop, "_check_health", side_effect=mock_check),
        patch.object(health_loop, "_act", side_effect=mock_act),
        patch.object(health_loop, "_heartbeat", side_effect=mock_heartbeat),
        patch("maude.healing.health_loop.asyncio.sleep", new=AsyncMock()),
    ):
        with pytest.raises(asyncio.CancelledError):
            await health_loop._loop()

    assert call_order == ["check", "act", "heartbeat"]


async def test_loop_continues_after_exception(health_loop: HealthLoop):
    """_loop catches non-CancelledError exceptions and continues."""
    call_count = 0

    async def mock_check():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise RuntimeError("transient failure")
        raise asyncio.CancelledError()

    with (
        patch.object(health_loop, "_check_health", side_effect=mock_check),
        patch("maude.healing.health_loop.asyncio.sleep", new=AsyncMock()),
    ):
        with pytest.raises(asyncio.CancelledError):
            await health_loop._loop()

    assert call_count == 2


async def test_loop_initial_delay(health_loop: HealthLoop):
    """_loop sleeps 10s initially before first check."""
    sleep_calls: list[float] = []

    async def track_sleep(seconds):
        sleep_calls.append(seconds)
        if len(sleep_calls) == 1:
            return  # Allow initial sleep
        raise asyncio.CancelledError()

    async def mock_check():
        return HealthStatus(healthy=True, action="none", reason="ok")

    with (
        patch.object(health_loop, "_check_health", side_effect=mock_check),
        patch.object(health_loop, "_act", new=AsyncMock()),
        patch.object(health_loop, "_heartbeat", new=AsyncMock()),
        patch("maude.healing.health_loop.asyncio.sleep", side_effect=track_sleep),
    ):
        with pytest.raises(asyncio.CancelledError):
            await health_loop._loop()

    assert 10 <= sleep_calls[0] <= 40  # Initial delay + jitter (0-30s)
    assert sleep_calls[1] == health_loop.hc.interval_seconds  # Loop interval


# ── Priority: endpoint unhealthy ignored when upstream_issue ──────


# ── memory_store integration ─────────────────────────────────────


def test_health_loop_accepts_memory_store(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Constructor accepts memory_store and wires callbacks."""
    config = HealthLoopConfig(enabled=True, interval_seconds=60)
    mock_store = MagicMock()
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
        memory_store=mock_store,
    )
    assert hl._embed_callback is mock_store.embed_and_store
    assert hl._past_fix_callback is not None


def test_health_loop_without_memory_store(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Constructor works without memory_store (callbacks are None)."""
    config = HealthLoopConfig(enabled=True, interval_seconds=60)
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
    )
    assert hl._embed_callback is None
    assert hl._past_fix_callback is None


def test_health_loop_accepts_explicit_callbacks(mock_audit: AsyncMock, mock_executor: AsyncMock):
    """Constructor accepts explicit embed and past_fix callbacks."""
    config = HealthLoopConfig(enabled=True, interval_seconds=60)
    mock_embed = AsyncMock()
    mock_past_fix = AsyncMock()
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test",
        project="test",
        health_config=config,
        embed_callback=mock_embed,
        past_fix_callback=mock_past_fix,
    )
    assert hl._embed_callback is mock_embed
    assert hl._past_fix_callback is mock_past_fix


# ── _classify_root_cause ────────────────────────────────────────


def test_classify_root_cause_service_crash(health_loop: HealthLoop):
    status = HealthStatus(service_active=False, reason="Service not active")
    assert health_loop._classify_root_cause(status) == "service_crash"


def test_classify_root_cause_endpoint_failure(health_loop: HealthLoop):
    status = HealthStatus(service_active=True, endpoint_healthy=False)
    assert health_loop._classify_root_cause(status) == "endpoint_failure"


def test_classify_root_cause_upstream(health_loop: HealthLoop):
    status = HealthStatus(service_active=True, domain_signals={"upstream_issue": True})
    assert health_loop._classify_root_cause(status) == "upstream_dependency"


def test_classify_root_cause_memory_exhaustion(health_loop: HealthLoop):
    status = HealthStatus(service_active=True, memory_percent=95)
    assert health_loop._classify_root_cause(status) == "memory_exhaustion"


def test_classify_root_cause_disk_pressure(health_loop: HealthLoop):
    status = HealthStatus(service_active=True, disk_percent=85)
    assert health_loop._classify_root_cause(status) == "disk_pressure"


def test_classify_root_cause_error_spike(health_loop: HealthLoop):
    status = HealthStatus(service_active=True, recent_errors=15)
    assert health_loop._classify_root_cause(status) == "error_spike"


def test_classify_root_cause_unknown(health_loop: HealthLoop):
    status = HealthStatus(service_active=True)
    assert health_loop._classify_root_cause(status) == "unknown"


# ── _check_past_fixes ───────────────────────────────────────────


async def test_check_past_fixes_no_memory_store(health_loop: HealthLoop):
    """Returns None when no memory_store configured."""
    health_loop._memory_store = None
    status = HealthStatus(healthy=False, reason="Service down")
    result = await health_loop._check_past_fixes(status)
    assert result is None


async def test_check_past_fixes_healthy_status(health_loop: HealthLoop):
    """Returns None when status is healthy."""
    health_loop._memory_store = AsyncMock()
    status = HealthStatus(healthy=True, reason="All clear")
    result = await health_loop._check_past_fixes(status)
    assert result is None


async def test_check_past_fixes_finds_match(health_loop: HealthLoop):
    """Returns past fix summary when callback returns a match string."""

    async def mock_past_fix(project: str, query: str) -> str | None:
        return "Actions: restart: succeeded; Root cause: service_crash"

    health_loop._past_fix_callback = mock_past_fix

    status = HealthStatus(healthy=False, reason="Service not active")
    result = await health_loop._check_past_fixes(status)
    assert result is not None
    assert "restart" in result.lower()


async def test_check_past_fixes_no_match(health_loop: HealthLoop):
    """Returns None when callback returns None."""

    async def mock_past_fix(project: str, query: str) -> str | None:
        return None

    health_loop._past_fix_callback = mock_past_fix

    status = HealthStatus(healthy=False, reason="Unknown issue")
    result = await health_loop._check_past_fixes(status)
    assert result is None


async def test_check_past_fixes_low_score(health_loop: HealthLoop):
    """Returns None when callback returns list with low-score memories."""
    from maude.memory.store import Memory

    low_score_memory = Memory(
        id=1,
        summary="Unrelated event",
        outcome="resolved",
        score=0.5,
    )

    async def mock_past_fix(project: str, query: str) -> list:
        return [low_score_memory]

    health_loop._past_fix_callback = mock_past_fix

    status = HealthStatus(healthy=False, reason="Service down")
    result = await health_loop._check_past_fixes(status)
    assert result is None


# ── _store_memory returns ID ────────────────────────────────────


async def test_store_memory_returns_id(health_loop: HealthLoop):
    """Refactored _store_memory returns the row ID via MemoryStore."""
    mock_store = AsyncMock()
    mock_store.store_memory = AsyncMock(return_value=42)
    health_loop._memory_store = mock_store

    status = HealthStatus(action="restart", reason="Service down")
    result = await health_loop._store_memory(status, "restart", "restart succeeded")
    assert result == 42


async def test_store_memory_returns_none_on_failure(health_loop: HealthLoop):
    """_store_memory returns None when MemoryStore write fails."""
    mock_store = AsyncMock()
    mock_store.store_memory = AsyncMock(side_effect=Exception("PG down"))
    health_loop._memory_store = mock_store

    status = HealthStatus(action="none", reason="All clear")
    result = await health_loop._store_memory(status, "none", "")
    assert result is None


# ── Priority: endpoint unhealthy ignored when upstream_issue ──────


async def test_check_health_endpoint_unhealthy_with_upstream_suppressed(
    mock_audit: AsyncMock, mock_executor: AsyncMock
):
    """Endpoint unhealthy + upstream_issue -> warn_upstream, not restart."""
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        health_endpoint="http://localhost:3000/health",
    )
    hl = HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="monitoring-server",
        project="monitoring",
        health_config=config,
    )
    hl.executor.run = AsyncMock(side_effect=_make_executor_responses())
    domain_result = {"upstream_issue": True, "detail": "DB connection lost"}
    hl.set_domain_checks(AsyncMock(return_value=domain_result))

    with (
        patch.object(hl, "_is_kill_switch_active", return_value=False),
        patch.object(hl, "_check_health_endpoint", return_value=(False, "HTTP 503")),
    ):
        status = await hl._check_health()

    # Upstream issue takes priority over endpoint unhealthy
    assert status.action == "warn_upstream"
    assert "DB connection lost" in status.reason


# ── Credential probe config parsing ──────────────────────────────


def test_config_with_credential_probes():
    data = {
        "enabled": True,
        "interval_seconds": 60,
        "credential_probes": [
            {
                "name": "technitium",
                "type": "http",
                "url": "http://localhost:5380/api/zones/list?token=${TECHNITIUM_API_TOKEN}",
                "expect_status": 200,
            },
            {"name": "postgres", "type": "pg", "section": "database.postgres"},
        ],
    }
    config = HealthLoopConfig.from_dict(data)
    assert len(config.credential_probes) == 2
    assert config.credential_probes[0].name == "technitium"
    assert config.credential_probes[0].probe_type == "http"
    assert config.credential_probes[1].probe_type == "pg"


def test_config_no_credential_probes():
    config = HealthLoopConfig.from_dict({"enabled": True})
    assert config.credential_probes == []


def test_credential_probe_env_substitution():
    import os

    os.environ["TEST_TOKEN"] = "secret123"
    probe = CredentialProbe(
        name="test",
        probe_type="http",
        url="http://localhost/api?token=${TEST_TOKEN}",
    )
    assert probe.resolve_url() == "http://localhost/api?token=secret123"
    del os.environ["TEST_TOKEN"]


def test_credential_probe_missing_env_var():
    probe = CredentialProbe(
        name="test",
        probe_type="http",
        url="http://localhost/api?token=${MISSING_VAR}",
    )
    assert "${MISSING_VAR}" in probe.resolve_url()


# ── Credential probe execution ───────────────────────────────────


@pytest.fixture
def health_loop_with_probes(mock_audit, mock_executor):
    config = HealthLoopConfig(
        enabled=True,
        interval_seconds=60,
        credential_probes=[
            CredentialProbe(
                name="test-api",
                probe_type="http",
                url="http://localhost:9999/api?token=good",
                expect_status=200,
            ),
        ],
    )
    return HealthLoop(
        executor=mock_executor,
        audit=mock_audit,
        service_name="test-svc",
        project="test",
        health_config=config,
    )


@pytest.mark.asyncio
async def test_credential_check_http_success(health_loop_with_probes):
    loop = health_loop_with_probes
    loop._http = AsyncMock()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    loop._http.get = AsyncMock(return_value=mock_resp)
    failures = await loop._check_credentials()
    assert failures == []


@pytest.mark.asyncio
async def test_credential_check_http_invalid_token(health_loop_with_probes):
    loop = health_loop_with_probes
    loop._http = AsyncMock()
    mock_resp = MagicMock()
    mock_resp.status_code = 401
    mock_resp.text = '{"status":"invalid-token"}'
    loop._http.get = AsyncMock(return_value=mock_resp)
    failures = await loop._check_credentials()
    assert len(failures) == 1
    assert "test-api" in failures[0]
    assert "401" in failures[0]


@pytest.mark.asyncio
async def test_credential_check_http_connection_error(health_loop_with_probes):
    import httpx

    loop = health_loop_with_probes
    loop._http = AsyncMock()
    loop._http.get = AsyncMock(side_effect=httpx.ConnectError("refused"))
    failures = await loop._check_credentials()
    assert len(failures) == 1
    assert "test-api" in failures[0]


@pytest.mark.asyncio
async def test_credential_check_vllm_all_hosts_down():
    config = HealthLoopConfig(
        enabled=True,
        credential_probes=[CredentialProbe(name="vllm", probe_type="vllm")],
    )
    loop = HealthLoop(
        executor=AsyncMock(),
        audit=AsyncMock(),
        service_name="test",
        project="test",
        health_config=config,
    )
    loop._http = AsyncMock()
    import httpx

    loop._http.get = AsyncMock(side_effect=httpx.ConnectError("refused"))
    with patch(
        "maude.healing.health_loop.resolve_infra_hosts",
        return_value={"vllm_hosts": ["localhost:8000"], "embedder_hosts": []},
    ):
        failures = await loop._check_credentials()
    assert len(failures) == 1
    assert "vllm" in failures[0]


# ── Credential probe wiring into decision tree ───────────────────


@pytest.mark.asyncio
async def test_health_check_escalates_on_credential_failure(health_loop_with_probes):
    """Failed credential probe triggers escalation, NOT restart."""
    loop = health_loop_with_probes
    loop._http = AsyncMock()
    mock_result = MagicMock(ok=True, stdout="active")
    loop.executor.run = AsyncMock(return_value=mock_result)
    # Health endpoint OK, credential check fails
    mock_resp_ok = MagicMock(status_code=200)
    mock_resp_ok.json = MagicMock(return_value={"status": "ok"})
    mock_resp_fail = MagicMock(status_code=401, text='{"status":"invalid-token"}')

    async def mock_get(url, **kwargs):
        if "token=" in str(url):
            return mock_resp_fail
        return mock_resp_ok

    loop._http.get = AsyncMock(side_effect=mock_get)
    with patch.object(loop, "_is_kill_switch_active", return_value=False):
        status = await loop._check_health()
    assert status.credentials_healthy is False
    assert len(status.credential_failures) == 1
    assert status.action == "escalate"
    assert "credential" in status.reason.lower()


# ── Issue tracking for Room Agent gating ─────────────────────────


def test_has_recent_issues_empty(health_loop: HealthLoop):
    """No issues recorded → has_recent_issues returns False."""
    assert health_loop.has_recent_issues() is False
    assert health_loop.get_recent_issues() == []


def test_has_recent_issues_after_issue(health_loop: HealthLoop):
    """After recording an issue, has_recent_issues returns True."""
    health_loop._issue_log.append((time.monotonic(), "restart", "Service not active"))
    assert health_loop.has_recent_issues() is True
    issues = health_loop.get_recent_issues()
    assert len(issues) == 1
    assert issues[0]["action"] == "restart"
    assert issues[0]["reason"] == "Service not active"


def test_has_recent_issues_old_issues_excluded(health_loop: HealthLoop):
    """Issues older than the window are excluded."""
    old_time = time.monotonic() - 8000  # > 2 hours ago
    health_loop._issue_log.append((old_time, "restart", "old issue"))
    assert health_loop.has_recent_issues(hours=2.0) is False
    assert health_loop.get_recent_issues(hours=2.0) == []


@pytest.mark.asyncio
async def test_act_records_issues(health_loop: HealthLoop):
    """The _act method records non-healthy statuses to _issue_log."""
    status = HealthStatus()
    status.healthy = False
    status.service_active = False
    status.action = "restart"
    status.reason = "Service not active"

    health_loop.executor.run = AsyncMock(return_value=MagicMock(ok=True, stdout="active"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        await health_loop._act(status)

    assert health_loop.has_recent_issues() is True
    issues = health_loop.get_recent_issues()
    assert any(i["reason"] == "Service not active" for i in issues)


@pytest.mark.asyncio
async def test_act_does_not_record_healthy(health_loop: HealthLoop):
    """Healthy status does NOT add to _issue_log."""
    status = HealthStatus()
    status.healthy = True
    status.action = "none"
    status.reason = "All checks passed"

    await health_loop._act(status)
    assert health_loop.has_recent_issues() is False


# ── Swap monitoring ───────────────────────────────────────────────


async def test_swap_threshold_triggers_escalation(health_loop: HealthLoop):
    """swap_percent > 80 triggers escalate action (restart won't help)."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses(swap_pct="85"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.healthy is False
    assert status.action == "escalate"
    assert "Swap high" in status.reason


async def test_swap_zero_total_reports_zero(health_loop: HealthLoop):
    """When total swap is 0, swap_percent should be 0 (not divide-by-zero)."""
    health_loop.executor.run = AsyncMock(side_effect=_make_executor_responses(swap_pct="0"))
    with patch.object(health_loop, "_is_kill_switch_active", return_value=False):
        status = await health_loop._check_health()

    assert status.swap_percent == 0
    assert status.healthy is True


def test_classify_root_cause_swap(health_loop: HealthLoop):
    """swap_percent > SWAP_THRESHOLD_PCT classifies as swap_pressure."""
    from maude.healing.health_checks import SWAP_THRESHOLD_PCT

    status = HealthStatus(service_active=True, swap_percent=SWAP_THRESHOLD_PCT + 5)
    assert health_loop._classify_root_cause(status) == "swap_pressure"


async def test_handle_upstream_escalates(health_loop: HealthLoop):
    """_handle_upstream publishes upstream_issue event and calls escalate."""
    callback = AsyncMock()
    health_loop.set_escalation_callback(callback)
    publisher = AsyncMock()
    health_loop._event_publisher = publisher

    status = HealthStatus(
        action="warn_upstream",
        reason="Upstream issue: PostgreSQL down",
        healthy=False,
    )
    with patch.object(health_loop, "_audit_action", new=AsyncMock()):
        await health_loop._handle_upstream(status)

    publisher.publish.assert_called_once()
    assert publisher.publish.call_args[0][0] == "upstream_issue"

    callback.assert_called_once()
    trigger = callback.call_args[0][0]
    assert "upstream_dependency" in trigger
