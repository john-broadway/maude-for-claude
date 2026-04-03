# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Background health loop for per-project MCP servers.

Replaces standalone guardian services. Runs inside the MCP daemon as an
asyncio background task. Calls the executor directly (no MCP protocol),
logs all decisions to audit as caller="concierge-staff".

Key behavior:
- Check service health every N seconds (configurable)
- Auto-restart unhealthy services (rate-limited: max 3/hour, 10min cooldown)
- Respect kill switch — skip restarts when readonly flag is set
- Optional health endpoint check (HTTP GET for application-level health)
- Optional domain checks callback (project-specific health signals)
- Send Uptime Kuma heartbeat on each cycle
- Never crash the MCP daemon — all errors caught

Decision priority:
1. Kill switch active → skip restart, log warning
2. Domain checks report upstream_issue → skip restart, log upstream
3. Service down → restart
4. Health endpoint unhealthy → restart
5. Error spike (>10 in 5min) → restart
6. Memory > 90% → restart
7. Disk > 80% → escalate (log warning, restart won't help)
8. All clear → heartbeat "up"

Usage:
    loop = HealthLoop(executor=ssh, audit=audit, config=svc_config, health_config={...})
    loop.set_domain_checks(my_domain_callback)
    await loop.start()
    # ... later ...
    await loop.stop()
"""

import asyncio
import logging
import random
import time
from contextlib import suppress
from typing import Any

import httpx

from maude.daemon.common import resolve_infra_hosts
from maude.healing.health_checks import (
    DISK_THRESHOLD_PCT,
    ERROR_THRESHOLD_COUNT,
    KILL_SWITCH_DIR,
    MEMORY_THRESHOLD_PCT,
    SWAP_THRESHOLD_PCT,
    CredentialProbe,
    DomainCheckCallback,
    EmbedCallback,
    EscalationCallback,
    HealthLoopConfig,
    HealthStatus,
    PastFixCallback,
    _status_to_context,
)
from maude.memory.audit import AuditLogger

logger = logging.getLogger(__name__)

# Re-export all types so existing `from maude.healing.health_loop import X` still works.
__all__ = [
    "DISK_THRESHOLD_PCT",
    "ERROR_THRESHOLD_COUNT",
    "KILL_SWITCH_DIR",
    "MEMORY_THRESHOLD_PCT",
    "SWAP_THRESHOLD_PCT",
    "CredentialProbe",
    "DomainCheckCallback",
    "EmbedCallback",
    "EscalationCallback",
    "HealthLoop",
    "HealthLoopConfig",
    "HealthStatus",
    "PastFixCallback",
    "_status_to_context",
]


class HealthLoop:
    """Background health monitor that runs inside the MCP daemon.

    Calls the executor directly (not through MCP protocol).
    Logs all decisions to audit as caller="concierge-staff".
    """

    CALLER = "concierge-staff"

    def __init__(
        self,
        executor: Any,
        audit: AuditLogger,
        service_name: str,
        project: str,
        health_config: HealthLoopConfig,
        event_publisher: Any | None = None,
        memory_store: Any | None = None,
        embed_callback: EmbedCallback | None = None,
        past_fix_callback: PastFixCallback | None = None,
        admin_registry: Any | None = None,
    ) -> None:
        self.executor = executor
        self.audit = audit
        self.service_name = service_name
        self.project = project
        self.hc = health_config
        self._restart_times: list[float] = []
        self._task: asyncio.Task[None] | None = None
        self._http: httpx.AsyncClient | None = None
        self._domain_checks: DomainCheckCallback | None = None
        self._escalation_callback: EscalationCallback | None = None
        self._event_publisher = event_publisher
        self._memory_store = memory_store
        self._admin_registry = admin_registry
        self._embed_callback = embed_callback
        self._past_fix_callback = past_fix_callback
        # Wire callbacks from memory_store if not explicitly provided
        if memory_store and not embed_callback:
            self._embed_callback = memory_store.embed_and_store
        if memory_store and not past_fix_callback:
            self._past_fix_callback = lambda project, query: memory_store.recall_similar(
                project, query, limit=3
            )
        self._kill_switch_path = KILL_SWITCH_DIR / project / "readonly"
        self._last_healthy: bool | None = None  # Track status transitions
        self._last_stored_action: str = ""  # Dedup repeated identical incidents
        self._heartbeat_failures: int = 0
        self._breach_cooldowns: dict[str, float] = {}
        # Recent issue log — Room Agent checks this to decide whether to run
        self._issue_log: list[tuple[float, str, str]] = []  # (monotonic, action, reason)

        # Predictive trend analysis (Phase 1A)
        from maude.analysis.trend_analyzer import TrendAnalyzer

        window_hours = self.hc.predictive.get("window_hours", 6)
        self._trends = TrendAnalyzer(window_hours=window_hours)
        self._breach_thresholds: dict[str, float] = self.hc.predictive.get(
            "breach_thresholds",
            {
                "disk_percent": float(DISK_THRESHOLD_PCT),
                "memory_percent": float(MEMORY_THRESHOLD_PCT),
                "swap_percent": float(SWAP_THRESHOLD_PCT),
            },
        )
        self._breach_horizon_hours: float = self.hc.predictive.get("breach_horizon_hours", 24.0)

    # ── Public API ────────────────────────────────────────────────

    def get_trends(self) -> Any:
        """Return the TrendAnalyzer for external consumers (e.g. ops.py)."""
        return self._trends

    def has_recent_issues(self, hours: float = 2.0) -> bool:
        """True if Layer 1 has seen any non-healthy status recently."""
        cutoff = time.monotonic() - (hours * 3600)
        return any(t > cutoff for t, _, _ in self._issue_log)

    def get_recent_issues(self, hours: float = 2.0) -> list[dict[str, str]]:
        """Recent Layer 1 issues for Room Agent context."""
        cutoff = time.monotonic() - (hours * 3600)
        return [{"action": a, "reason": r} for t, a, r in self._issue_log if t > cutoff]

    def set_domain_checks(self, callback: DomainCheckCallback) -> None:
        """Register a domain-specific health check callback.

        The callback should return a dict with domain signals, e.g.:
            {"upstream_issue": True, "detail": "PostgreSQL datasource down"}
            {"alerts_firing": 3}

        If "upstream_issue" is truthy, the health loop will NOT restart
        the service (the problem is elsewhere).
        """
        self._domain_checks = callback

    def set_escalation_callback(self, callback: EscalationCallback) -> None:
        """Register a callback for escalation events.

        When the health loop encounters a situation it cannot handle
        (e.g., rate-limited restarts, disk full, persistent failures),
        it calls this callback to hand off to a Room Agent.

        The callback receives:
            trigger: str — description of the escalation event
            context: dict — health status details
        """
        self._escalation_callback = callback

    async def start(self) -> None:
        """Start the health loop as a background asyncio task."""
        if not self.hc.enabled:
            logger.info("Health loop disabled for %s", self.project)
            return
        skip_verify = self.hc.health_endpoint and self.hc.health_endpoint.startswith("https")
        self._http = httpx.AsyncClient(
            timeout=float(self.hc.health_endpoint_timeout),
            verify=not skip_verify,
        )
        self._task = asyncio.create_task(self._loop(), name=f"health-loop-{self.project}")
        logger.info(
            "Health loop started for %s (interval=%ds, heartbeat=%s, health_endpoint=%s)",
            self.project,
            self.hc.interval_seconds,
            bool(self.hc.heartbeat_url),
            bool(self.hc.health_endpoint),
        )

    async def stop(self) -> None:
        """Stop the health loop gracefully."""
        if self._task:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        if self._http:
            await self._http.aclose()
            self._http = None
        logger.info("Health loop stopped for %s", self.project)

    # ── Main loop ─────────────────────────────────────────────────

    async def _loop(self) -> None:
        """Main loop — check health, act, heartbeat, repeat."""
        # Initial delay to let the MCP server finish startup + jitter
        await asyncio.sleep(10 + random.uniform(0, 30))

        while True:
            try:
                status = await self._check_health()
                await self._act(status)
                await self._heartbeat(status)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Health loop error (non-fatal, continuing)")

            await asyncio.sleep(self.hc.interval_seconds)

    # ── Health checking (decomposed) ──────────────────────────────

    def _is_kill_switch_active(self) -> bool:
        """Check if the kill switch readonly flag exists."""
        return self._kill_switch_path.exists()

    async def _check_health(self) -> HealthStatus:
        """Run all health checks and return composite status."""
        status = HealthStatus()

        # Gather signals
        status.kill_switch_active = self._is_kill_switch_active()
        await self._check_service_state(status)
        await self._check_endpoint(status)
        await self._check_domain_and_credentials(status)
        await self._check_resources(status)

        # Record metrics for trend analysis
        self._record_trends(status)

        # Evaluate composite health decision
        self._evaluate_health(status)

        return status

    async def _check_service_state(self, status: HealthStatus) -> None:
        """Check systemctl is-active for the service."""
        result = await self.executor.run(f"systemctl is-active {self.service_name}")
        status.service_active = result.stdout.strip() == "active"

    async def _check_endpoint(self, status: HealthStatus) -> None:
        """Check the optional HTTP health endpoint."""
        endpoint_ok, endpoint_detail = await self._check_health_endpoint()
        if self.hc.health_endpoint:
            status.endpoint_healthy = endpoint_ok
            status.endpoint_detail = endpoint_detail

    async def _check_domain_and_credentials(self, status: HealthStatus) -> None:
        """Run domain checks and credential probes."""
        status.domain_signals = await self._run_domain_checks()
        cred_failures = await self._check_credentials()
        if cred_failures:
            status.credentials_healthy = False
            status.credential_failures = cred_failures

    async def _check_resources(self, status: HealthStatus) -> None:
        """Check memory, disk, and recent error count."""
        # Memory usage
        mem_result = await self.executor.run("free -m | awk '/^Mem:/ {printf \"%.0f\", $3/$2*100}'")
        if mem_result.ok and mem_result.stdout.strip().isdigit():
            status.memory_percent = int(mem_result.stdout.strip())

        # Swap usage
        swap_result = await self.executor.run(
            'free -m | awk \'/^Swap:/ {if ($2>0) printf "%.0f", $3/$2*100; else print "0"}\''
        )
        if swap_result.ok and swap_result.stdout.strip().isdigit():
            status.swap_percent = int(swap_result.stdout.strip())

        # Disk usage
        disk_result = await self.executor.run("df -h / | awk 'NR==2 {print $5}' | tr -d '%'")
        if disk_result.ok and disk_result.stdout.strip().isdigit():
            status.disk_percent = int(disk_result.stdout.strip())

        # Recent errors (last 5 minutes)
        err_result = await self.executor.run(
            f"journalctl -u {self.service_name} --since '5 min ago' -p err --no-pager -q | wc -l"
        )
        if err_result.ok and err_result.stdout.strip().isdigit():
            status.recent_errors = int(err_result.stdout.strip())

    def _record_trends(self, status: HealthStatus) -> None:
        """Record metrics for the TrendAnalyzer."""
        self._trends.record("disk_percent", float(status.disk_percent))
        self._trends.record("memory_percent", float(status.memory_percent))
        self._trends.record("swap_percent", float(status.swap_percent))
        if self.hc.health_endpoint and status.endpoint_healthy is not None:
            self._trends.record("recent_errors", float(status.recent_errors))

    def _evaluate_health(self, status: HealthStatus) -> None:
        """Decision tree: determine overall health and required action."""
        upstream_issue = status.domain_signals.get("upstream_issue", False)
        can_restart = self.hc.max_restart_attempts > 0

        if not status.service_active and can_restart:
            status.healthy = False
            status.action = "restart"
            status.reason = "Service not active"
        elif not status.credentials_healthy:
            status.healthy = False
            status.action = "escalate"
            status.reason = f"Credential expired: {'; '.join(status.credential_failures)}"
        elif status.endpoint_healthy is False and not upstream_issue:
            status.healthy = False
            status.action = "restart" if can_restart else "escalate"
            status.reason = f"Health endpoint unhealthy: {status.endpoint_detail}"
        elif upstream_issue:
            detail = status.domain_signals.get("detail", "upstream dependency down")
            status.healthy = False
            status.action = "warn_upstream"
            status.reason = f"Upstream issue: {detail}"
        elif status.recent_errors > ERROR_THRESHOLD_COUNT:
            status.healthy = False
            status.action = "restart" if can_restart else "escalate"
            status.reason = f"Error spike: {status.recent_errors} errors in 5min"
        elif status.memory_percent > MEMORY_THRESHOLD_PCT:
            status.healthy = False
            status.action = "restart" if can_restart else "escalate"
            status.reason = f"Memory critical: {status.memory_percent}%"
        elif status.swap_percent > SWAP_THRESHOLD_PCT:
            status.healthy = False
            status.action = "escalate"
            status.reason = f"Swap high: {status.swap_percent}% (restart won't help)"
        elif status.disk_percent > DISK_THRESHOLD_PCT:
            status.healthy = False
            status.action = "escalate"
            status.reason = f"Disk high: {status.disk_percent}% (restart won't help)"
        else:
            status.healthy = True
            status.action = "none"
            status.reason = "All checks passed"

    # ── Health endpoint + domain helpers ───────────────────────────

    async def _check_health_endpoint(self) -> tuple[bool, str]:
        """Check the optional HTTP health endpoint.

        Returns:
            (healthy, detail) tuple.
        """
        if not self.hc.health_endpoint or not self._http:
            return True, ""

        try:
            resp = await self._http.get(self.hc.health_endpoint)
            if resp.status_code != 200:
                return False, f"HTTP {resp.status_code}"
            # Try to parse JSON for richer detail (informational only)
            try:
                data = resp.json()
                status = data.get("status", data.get("database", "ok"))
                return True, f"ok ({status})"
            except Exception:
                return True, "ok"
        except httpx.ConnectTimeout:
            return False, "connect timeout"
        except httpx.ReadTimeout:
            return False, "read timeout (endpoint slow)"
        except httpx.ConnectError as e:
            cause = type(e.__cause__).__name__ if e.__cause__ else "unknown"
            return False, f"connection failed ({cause})"
        except httpx.TimeoutException:
            return False, "timeout"
        except Exception as e:
            return False, f"{type(e).__name__}: {str(e)[:80]}"

    async def _run_domain_checks(self) -> dict[str, Any]:
        """Run the optional domain-specific health checks."""
        if not self._domain_checks:
            return {}
        try:
            return await self._domain_checks()
        except Exception:
            logger.exception("Domain check callback failed (non-fatal)")
            return {"error": "domain check failed"}

    # ── Action handling (decomposed) ──────────────────────────────

    async def _act(self, status: HealthStatus) -> None:
        """Take action based on health status."""
        # Publish health_status_changed on transitions
        if self._last_healthy is not None and status.healthy != self._last_healthy:
            await self._publish_event(
                "health_status_changed",
                {
                    "status": "healthy" if status.healthy else "unhealthy",
                    "reason": status.reason,
                    "action": status.action,
                },
            )
        self._last_healthy = status.healthy
        if status.healthy:
            self._last_stored_action = ""  # Reset dedup on recovery

        # Predictive breach detection
        await self._check_breach_predictions()

        # Track issues for Room Agent gating
        if status.action != "none":
            now = time.monotonic()
            self._issue_log.append((now, status.action, status.reason))
            # Keep last 2 hours
            cutoff = now - 7200
            self._issue_log = [e for e in self._issue_log if e[0] > cutoff]

        action_taken = "none"
        action_result = ""

        if status.action == "restart":
            action_taken, action_result = await self._handle_restart(status)
        elif status.action == "warn_upstream":
            action_taken, action_result = await self._handle_upstream(status)
        elif status.action == "escalate":
            action_taken, action_result = await self._handle_escalation(status)
        elif status.action == "none":
            logger.debug("HEALTH: %s healthy", self.service_name)

        # Only persist when something happened (restart, escalation, upstream).
        # Routine "all healthy" checks generate ~400K rows/day fleet-wide.
        # Also skip storing when the same action+reason repeats — a room stuck
        # in "Service not active" doesn't need 10K identical incident records.
        mem_id: int | None = None
        if status.action != "none":
            action_key = f"{status.action}:{status.reason}"
            if action_key != self._last_stored_action:
                mem_id = await self._store_memory(status, action_taken, action_result)
                self._last_stored_action = action_key
            else:
                logger.debug(
                    "HEALTH: skipping duplicate memory for %s: %s",
                    self.service_name,
                    action_key,
                )

        # Embed significant events to Qdrant for future semantic recall
        if self._embed_callback and mem_id and status.action != "none":
            await self._embed_event(status, action_taken, action_result, mem_id)

    async def _check_breach_predictions(self) -> None:
        """Predictive breach detection — warn before thresholds are hit."""
        for metric, threshold in self._breach_thresholds.items():
            breach_secs = self._trends.predict_breach(metric, threshold)
            if breach_secs is None:
                continue
            breach_hours = breach_secs / 3600
            if breach_hours >= self._breach_horizon_hours:
                continue
            # Cooldown: don't spam the same metric more than once per 15 min
            now = time.monotonic()
            last_fired = self._breach_cooldowns.get(metric, 0.0)
            if now - last_fired < 900:
                continue
            self._breach_cooldowns[metric] = now

            logger.warning(
                "HEALTH: Predicted %s breach of %.0f%% in %.1f hours for %s",
                metric,
                threshold,
                breach_hours,
                self.service_name,
            )
            await self._publish_event(
                "predictive_warning",
                {
                    "metric": metric,
                    "threshold": threshold,
                    "breach_hours": round(breach_hours, 1),
                },
            )

    async def _handle_restart(self, status: HealthStatus) -> tuple[str, str]:
        """Handle restart action — kill switch, rate limiting, or execute."""
        if status.kill_switch_active:
            return await self._restart_blocked_kill_switch(status)
        if self._can_restart():
            return await self._attempt_restart(status)
        return await self._restart_rate_limited(status)

    async def _restart_blocked_kill_switch(self, status: HealthStatus) -> tuple[str, str]:
        """Restart blocked because kill switch is active."""
        logger.warning(
            "HEALTH: %s needs restart but kill switch is active — skipping",
            self.service_name,
        )
        await self._audit_action(
            "restart_blocked_kill_switch",
            status.reason,
            "Kill switch active: restart skipped",
            True,
        )
        return "restart", "Kill switch active: restart skipped"

    async def _attempt_restart(self, status: HealthStatus) -> tuple[str, str]:
        """Execute a restart and record the result.

        Uses restart_command from config if set (for Docker Compose, etc.),
        otherwise falls back to systemctl restart.
        """
        restart_cmd = self.hc.restart_command or f"systemctl restart {self.service_name}"
        logger.warning(
            "HEALTH: Restarting %s — %s (cmd: %s)",
            self.service_name,
            status.reason,
            restart_cmd,
        )
        result = await self.executor.run(restart_cmd)
        self._restart_times.append(time.monotonic())
        success = result.ok
        await self._audit_action(
            "auto_restart",
            status.reason,
            f"restart {'succeeded' if success else 'failed'}",
            success,
        )
        await self._publish_event(
            "restart_performed",
            {
                "reason": status.reason,
                "success": success,
            },
        )
        return "restart", f"restart {'succeeded' if success else 'failed'}"

    async def _restart_rate_limited(self, status: HealthStatus) -> tuple[str, str]:
        """Restart rate-limited — try auto-resolve, then escalate."""
        # Layer 1.5: Try pattern-based auto-resolution before escalating
        auto = await self._try_auto_resolve(status)
        if auto:
            return auto

        logger.warning(
            "HEALTH: %s unhealthy but restart rate-limited — %s",
            self.service_name,
            status.reason,
        )
        await self._audit_action(
            "restart_rate_limited",
            status.reason,
            "Rate limited: too many recent restarts",
            True,
        )
        await self._publish_event(
            "escalation",
            {
                "trigger": "restart_rate_limited",
                "reason": status.reason,
            },
        )
        ctx = _status_to_context(status)
        past_fix = await self._check_past_fixes(status)
        if past_fix:
            ctx["past_fix"] = past_fix
        await self._escalate(
            f"health_loop_restart_rate_limited: {status.reason}",
            ctx,
        )
        return "restart", "Rate limited: too many recent restarts"

    async def _handle_upstream(self, status: HealthStatus) -> tuple[str, str]:
        """Handle upstream issue — log but don't restart."""
        logger.warning(
            "HEALTH: %s has upstream issue — %s (NOT restarting)",
            self.service_name,
            status.reason,
        )
        await self._audit_action(
            "upstream_issue",
            status.reason,
            "Upstream dependency problem: restart suppressed",
            True,
        )
        ctx = _status_to_context(status)
        await self._publish_event(
            "upstream_issue",
            {
                "reason": status.reason,
                "upstream": status.reason,
            },
        )
        await self._escalate(f"upstream_dependency: {status.reason}", ctx)
        return "warn_upstream", "Upstream dependency problem: restart suppressed"

    async def _handle_escalation(self, status: HealthStatus) -> tuple[str, str]:
        """Handle escalation — manual intervention needed."""
        logger.warning(
            "HEALTH: %s needs attention — %s",
            self.service_name,
            status.reason,
        )
        await self._audit_action(
            "escalation",
            status.reason,
            "Escalated: manual intervention needed",
            True,
        )
        await self._publish_event(
            "escalation",
            {
                "trigger": "health_loop_escalation",
                "reason": status.reason,
            },
        )
        ctx = _status_to_context(status)
        past_fix = await self._check_past_fixes(status)
        if past_fix:
            ctx["past_fix"] = past_fix
        await self._escalate(
            f"health_loop_escalation: {status.reason}",
            ctx,
        )
        return "escalate", "Escalated: manual intervention needed"

    async def _embed_event(
        self,
        status: HealthStatus,
        action_taken: str,
        action_result: str,
        mem_id: int,
    ) -> None:
        """Embed significant events to Qdrant for future semantic recall."""
        root_cause = self._classify_root_cause(status)
        tools = [action_taken] if action_taken != "none" else []
        embed_type = "incident" if status.action == "restart" else "escalation"
        embed_outcome = "resolved" if "succeeded" in action_result else "escalated"
        try:
            await self._embed_callback(  # type: ignore[misc]
                memory_id=mem_id,
                summary=f"{self.project}: {status.reason} → {action_taken} → {action_result}",
                memory_type=embed_type,
                outcome=embed_outcome,
                actions_summary=f"{action_taken}: {action_result}",
                root_cause=root_cause,
                tools_used=tools,
            )
        except Exception:
            logger.debug("HealthLoop: Qdrant embed failed (non-fatal)")

    # ── Escalation ────────────────────────────────────────────────

    async def _escalate(self, trigger: str, context: dict[str, Any]) -> None:
        """Invoke the escalation callback if registered."""
        if not self._escalation_callback:
            logger.info("HEALTH: Escalation triggered but no callback registered: %s", trigger)
            return

        try:
            await self._escalation_callback(trigger, context)
        except Exception:
            logger.exception("HEALTH: Escalation callback failed (non-fatal)")

    # ── Layer 1.5 auto-resolve ────────────────────────────────────

    async def _try_auto_resolve(self, status: HealthStatus) -> tuple[str, str] | None:
        """Layer 1.5 — Try pattern-based auto-resolution from local memory.

        Checks SQLite for past successful remediations matching this issue.
        If AdminRegistry allows the action, execute it autonomously.
        No LLM needed — pure rule-based from local history.

        Returns (action_taken, action_result) if resolved, or None.
        """
        local_store = getattr(self._memory_store, "_local", None) if self._memory_store else None
        if not local_store or not self._admin_registry:
            return None

        root_cause = self._classify_root_cause(status)
        try:
            past_fix = await local_store.find_past_fix(root_cause)
        except Exception:
            return None

        if not past_fix:
            return None

        # past_fix is a dict with keys: root_cause, action, success_rate, occurrences
        action_name = past_fix.get("action", "")
        if not action_name:
            return None
        # Normalize action names — "restart" variants map to "restart_service"
        if "restart" in action_name.lower():
            action_name = "restart_service"

        result = self._admin_registry.check_guardrails(action_name)
        if not result.allowed:
            logger.debug(
                "HEALTH: Layer 1.5 match but guardrail blocked: %s (%s)",
                action_name,
                result.reason,
            )
            return None

        if not self._can_restart():
            return None

        # Execute the pattern-matched fix
        fix_desc = (
            f"{past_fix.get('action', '?')} "
            f"(rate={past_fix.get('success_rate', 0):.0%}, "
            f"n={past_fix.get('occurrences', 0)})"
        )
        logger.info(
            "HEALTH: Layer 1.5 auto-resolve for %s — %s (pattern: %s)",
            self.service_name,
            action_name,
            fix_desc,
        )
        restart_cmd = self.hc.restart_command or f"systemctl restart {self.service_name}"
        exec_result = await self.executor.run(restart_cmd)
        self._restart_times.append(time.monotonic())
        success = exec_result.ok

        await self._audit_action(
            "auto_resolve_pattern",
            f"Layer 1.5: {root_cause} → {fix_desc}",
            f"pattern-based restart {'succeeded' if success else 'failed'}",
            success,
        )
        await self._publish_event(
            "auto_resolve",
            {
                "layer": "1.5",
                "root_cause": root_cause,
                "past_fix": fix_desc,
                "success": success,
            },
        )
        return (
            "auto_resolve",
            f"Layer 1.5 pattern match: {fix_desc} → {'succeeded' if success else 'failed'}",
        )

    # ── Classification and past fix lookup ────────────────────────

    def _classify_root_cause(self, status: HealthStatus) -> str:
        """Classify the root cause of a health event."""
        if not status.service_active:
            return "service_crash"
        if status.endpoint_healthy is False:
            return "endpoint_failure"
        if status.domain_signals.get("upstream_issue"):
            return "upstream_dependency"
        if status.memory_percent > MEMORY_THRESHOLD_PCT:
            return "memory_exhaustion"
        if status.disk_percent > DISK_THRESHOLD_PCT:
            return "disk_pressure"
        if status.swap_percent > SWAP_THRESHOLD_PCT:
            return "swap_pressure"
        if status.recent_errors > ERROR_THRESHOLD_COUNT:
            return "error_spike"
        if not status.credentials_healthy:
            return "credential_expired"
        return "unknown"

    async def _check_credentials(self) -> list[str]:
        """Run credential probes. Returns list of failure descriptions."""
        if not self.hc.credential_probes or not self._http:
            return []
        failures: list[str] = []
        for probe in self.hc.credential_probes:
            try:
                if probe.probe_type == "http":
                    url = probe.resolve_url()
                    resp = await self._http.get(url, timeout=float(probe.timeout))
                    if resp.status_code != probe.expect_status:
                        body = resp.text[:100] if hasattr(resp, "text") else ""
                        failures.append(
                            f"{probe.name}: HTTP {resp.status_code} "
                            f"(expected {probe.expect_status}) — {body}"
                        )
                elif probe.probe_type == "pg":
                    await self._check_pg_credential(probe, failures)
                elif probe.probe_type == "vllm":
                    await self._check_vllm_credential(probe, failures)
            except httpx.TimeoutException:
                failures.append(f"{probe.name}: timeout after {probe.timeout}s")
            except httpx.ConnectError as e:
                failures.append(f"{probe.name}: connection failed — {e}")
            except Exception as e:
                failures.append(f"{probe.name}: {type(e).__name__}: {str(e)[:80]}")
        return failures

    async def _check_pg_credential(
        self,
        probe: CredentialProbe,
        failures: list[str],
    ) -> None:
        """Test a PostgreSQL credential from secrets.yaml."""
        try:
            from maude.daemon.common import load_credentials

            parts = probe.section.split(".")
            creds = load_credentials()
            for part in parts:
                creds = creds[part]
            import asyncpg

            conn = await asyncpg.connect(
                host=creds.get("host", "localhost"),
                port=creds.get("port", 5432),
                user=creds.get("user", ""),
                password=creds.get("password", ""),
                database=creds.get("name", "agent"),
                timeout=float(probe.timeout),
            )
            await conn.fetchval("SELECT 1")
            await conn.close()
        except Exception as e:
            failures.append(f"{probe.name}: {type(e).__name__}: {str(e)[:80]}")

    async def _check_vllm_credential(
        self,
        probe: CredentialProbe,
        failures: list[str],
    ) -> None:
        """Test vLLM host reachability."""
        infra = resolve_infra_hosts()
        hosts = infra.get("vllm_hosts", [])
        if not hosts:
            failures.append(f"{probe.name}: no vLLM hosts configured")
            return
        reachable = 0
        for host in hosts:
            try:
                url = f"http://{host}/health" if "://" not in host else f"{host}/health"
                resp = await self._http.get(url, timeout=float(probe.timeout))  # type: ignore[union-attr]
                if resp.status_code == 200:
                    reachable += 1
            except Exception:
                pass
        if reachable == 0:
            failures.append(f"{probe.name}: all {len(hosts)} hosts unreachable")

    async def _check_past_fixes(self, status: HealthStatus) -> str | None:
        """Check if a similar issue was resolved before. Returns past fix summary or None."""
        if not self._past_fix_callback or status.healthy:
            return None
        try:
            query = f"{self.project} {status.reason}"
            result = await self._past_fix_callback(self.project, query)
            if isinstance(result, str):
                return result
            # Backward compat: callback may return list of memory objects
            if isinstance(result, list):
                for m in result:
                    resolved = getattr(m, "outcome", "") in ("resolved", "remediated")
                    if resolved and getattr(m, "score", 0) > 0.75:
                        return getattr(m, "reasoning", None) or getattr(m, "summary", None)
        except Exception:
            logger.debug("HealthLoop: past fix lookup failed (non-fatal)")
        return None

    # ── Rate limiting ─────────────────────────────────────────────

    def _can_restart(self) -> bool:
        """Check if we're allowed to restart (rate limiting)."""
        now = time.monotonic()

        # Prune restarts older than 1 hour
        self._restart_times = [t for t in self._restart_times if now - t < 3600]

        # Check max attempts per hour
        if len(self._restart_times) >= self.hc.max_restart_attempts:
            return False

        # Check cooldown since last restart
        if self._restart_times:
            last = self._restart_times[-1]
            if now - last < self.hc.cooldown_seconds:
                return False

        return True

    # ── Heartbeat ─────────────────────────────────────────────────

    async def _heartbeat(self, status: HealthStatus) -> None:
        """Send heartbeat to Uptime Kuma push monitor."""
        if not self.hc.heartbeat_url or not self._http:
            return

        beat_status = "up" if status.healthy else "down"
        msg = status.reason[:100]
        url = f"{self.hc.heartbeat_url}?status={beat_status}&msg={msg}"

        try:
            resp = await self._http.get(url)
            if resp.status_code != 200:
                logger.warning("Heartbeat HTTP %d from %s", resp.status_code, url)
                self._heartbeat_failures += 1
            else:
                self._heartbeat_failures = 0
        except Exception:
            self._heartbeat_failures += 1
            if self._heartbeat_failures >= 5:
                logger.warning(
                    "Heartbeat failed %d consecutive times: %s",
                    self._heartbeat_failures,
                    self.hc.heartbeat_url,
                )
            else:
                logger.debug("Heartbeat failed (non-fatal): %s", self.hc.heartbeat_url)

    # ── Event publishing ──────────────────────────────────────────

    async def _publish_event(self, event_type: str, data: dict[str, Any]) -> None:
        """Publish an event if the event publisher is configured."""
        if self._event_publisher:
            try:
                await self._event_publisher.publish(event_type, data)
            except Exception:
                logger.debug("Health loop event publish failed (non-fatal)")

    # ── Memory storage ────────────────────────────────────────────

    async def _store_memory(
        self,
        status: HealthStatus,
        action_taken: str,
        action_result: str,
    ) -> int | None:
        """Write a health check record via MemoryStore (SQLite-first → PG).

        Returns PG row ID, or None if PG is unavailable (still stored locally).
        """
        if not self._memory_store:
            return None

        # Map action → memory_type and outcome
        if status.action == "none":
            memory_type = "check"
            outcome = "no_action"
        elif status.action == "restart":
            memory_type = "incident"
            if status.kill_switch_active:
                outcome = "failed"
            elif action_result.startswith("Rate limited"):
                memory_type = "escalation"
                outcome = "escalated"
            elif "succeeded" in action_result:
                outcome = "resolved"
            else:
                outcome = "failed"
        elif status.action == "warn_upstream":
            memory_type = "check"
            outcome = "no_action"
        elif status.action == "escalate":
            memory_type = "escalation"
            outcome = "escalated"
        else:
            memory_type = "check"
            outcome = "no_action"

        # Build summary line
        ep = status.endpoint_detail or ("ok" if status.endpoint_healthy is not False else "fail")
        if status.action == "none":
            summary = (
                f"\u2713 active mem={status.memory_percent}% "
                f"disk={status.disk_percent}% err={status.recent_errors} endpoint={ep}"
            )
        elif status.action == "restart":
            if status.kill_switch_active:
                summary = "\U0001f512 kill switch: restart blocked"
            elif action_result.startswith("Rate limited"):
                summary = f"\u26a0 escalated: {status.reason}"
            else:
                summary = f"\u21bb restarted: {status.reason}"
        elif status.action == "warn_upstream":
            summary = f"\u26a1 upstream: {status.reason}"
        elif status.action == "escalate":
            summary = f"\u26a0 escalated: {status.reason}"
        else:
            summary = status.reason

        # Routine "all good" checks are noise — skip PG storage.
        # Trends are tracked separately via _trends.record().
        # Only store actionable outcomes (incidents, escalations, restarts).
        if memory_type == "check" and outcome == "no_action":
            return None

        context = _status_to_context(status)
        actions_taken: list[dict[str, Any]] = []
        if action_taken != "none":
            actions_taken.append({"action": action_taken, "result": action_result})

        root_cause = self._classify_root_cause(status)

        try:
            return await self._memory_store.store_memory(
                project=self.project,
                memory_type=memory_type,
                summary=summary,
                trigger="health_loop",
                context=context,
                reasoning="",
                actions_taken=actions_taken,
                outcome=outcome,
                tokens_used=0,
                model="health_loop",
                root_cause=root_cause,
            )
        except Exception:
            logger.warning("HealthLoop: Failed to write memory (non-fatal)")
            return None

    # ── Audit ─────────────────────────────────────────────────────

    async def _audit_action(
        self,
        action: str,
        reason: str,
        result: str,
        success: bool,
    ) -> None:
        """Log a health loop action to the audit trail."""
        try:
            await self.audit.log_tool_call(
                tool=f"health_loop.{action}",
                caller=self.CALLER,
                params={"service": self.service_name, "reason": reason},
                result=result,
                success=success,
                duration_ms=0,
                reason=reason,
            )
        except Exception:
            logger.exception("Health loop audit write failed (non-fatal)")
