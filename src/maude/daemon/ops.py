"""Standard operational tools for Maude MCP servers.

Extracts the 11 base tools that every Room gets into a standalone
register function. Rooms compose these via function call.

Usage:
    from maude.daemon.ops import register_ops_tools
    register_ops_tools(mcp, executor, audit, kill_switch, "redis-server", "redis")

Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
         Claude (Anthropic) <noreply@anthropic.com>
Version: 1.0.0
Updated: 2026-02-12
"""

import logging
from typing import Any

from maude.daemon.audit import AuditLogger
from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.db import format_json as _format
from maude.healing.health_checks import (
    DISK_THRESHOLD_PCT,
    ERROR_THRESHOLD_COUNT,
    MEMORY_THRESHOLD_PCT,
)

logger = logging.getLogger(__name__)


async def gather_health_data(
    ssh: Any,
    service_name: str,
    project: str,
    ctid: int,
) -> dict[str, Any]:
    """Gather composite health data: service state + resource usage.

    Shared between the ``service_health`` tool and the ``room_status``
    MCP resource. Returns a dict suitable for JSON serialization.
    """
    checks: dict[str, Any] = {"project": project, "ctid": ctid}
    healthy = True

    # 1. Service state
    svc_result = await ssh.run(f"systemctl is-active {service_name}")
    svc_active = svc_result.stdout == "active"
    checks["service_active"] = svc_active
    if not svc_active:
        healthy = False

    # 2. Memory usage
    mem_result = await ssh.run("free -m | awk '/^Mem:/ {printf \"%.0f\", $3/$2*100}'")
    if mem_result.ok:
        try:
            mem_pct = int(mem_result.stdout)
        except (ValueError, TypeError):
            mem_pct = 0
        checks["memory_percent"] = mem_pct
        if mem_pct > MEMORY_THRESHOLD_PCT:
            healthy = False
            checks["memory_warning"] = True

    # 3. Disk usage
    disk_result = await ssh.run("df -h / | awk 'NR==2 {print $5}' | tr -d '%'")
    if disk_result.ok:
        try:
            disk_pct = int(disk_result.stdout)
        except (ValueError, TypeError):
            disk_pct = 0
        checks["disk_percent"] = disk_pct
        if disk_pct > DISK_THRESHOLD_PCT:
            healthy = False
            checks["disk_warning"] = True

    # 4. Recent errors (last 5 minutes)
    err_result = await ssh.run(
        f"journalctl -u {service_name} --since '5 min ago' -p err --no-pager -q | wc -l"
    )
    if err_result.ok:
        try:
            error_count = int(err_result.stdout)
        except (ValueError, TypeError):
            error_count = 0
        checks["recent_errors_5m"] = error_count
        if error_count > ERROR_THRESHOLD_COUNT:
            healthy = False
            checks["error_spike"] = True

    checks["healthy"] = healthy
    checks["status"] = "healthy" if healthy else "unhealthy"
    return checks


def register_ops_tools(
    mcp: Any,
    executor: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    service_name: str,
    project: str,
    *,
    ctid: int = 0,
    ip: str = "",
    health_loop: Any | None = None,
    health_loop_ref: Any | None = None,
) -> None:
    """Register 11 standard operational tools on a FastMCP instance.

    Tools registered:
        Read-only: service_status, service_health, service_logs, service_errors,
                   service_log_patterns, service_trends
        Guarded:   service_restart, service_log_cleanup
        Admin:     kill_switch_status, kill_switch_activate, kill_switch_deactivate

    Args:
        mcp: FastMCP instance to register tools on.
        executor: SSHExecutor or LocalExecutor for running commands.
        audit: AuditLogger for audit trail.
        kill_switch: KillSwitch for guarding write operations.
        service_name: systemd unit name (e.g., "redis-server").
        project: Project identifier (e.g., "redis").
        ctid: Optional container ID for status metadata.
        ip: Optional IP address for status metadata.
        health_loop: Direct HealthLoop reference for service_trends tool.
            Use this when the health loop is already created at registration time.
        health_loop_ref: Object with ``_health_loop`` attribute. The attribute
            is read at tool call time, allowing the health loop to be set
            after registration. Takes precedence over ``health_loop``
            when provided.
    """
    # If no explicit health_loop_ref, create a deferred container on the MCP
    # instance so run_with_lifecycle() can populate it after health loop creation.
    if health_loop_ref is None and health_loop is None:
        if not hasattr(mcp, "_maude_health_loop_ref"):

            class _DeferredHealthRef:
                _health_loop: Any = None

            mcp._maude_health_loop_ref = _DeferredHealthRef()
        health_loop_ref = mcp._maude_health_loop_ref

    _register_status_tools(mcp, executor, audit, service_name, project, ctid, ip)
    _register_log_tools(mcp, executor, audit, service_name)
    _register_lifecycle_tools(mcp, executor, audit, kill_switch, service_name)
    _register_admin_tools(mcp, audit, kill_switch)
    _register_capacity_tools(mcp, executor, audit, kill_switch, service_name)
    _register_log_analysis_tools(mcp, executor, audit, service_name)
    _register_predictive_tools(mcp, audit, project, health_loop, health_loop_ref)

    # LLM security scanning (garak-inspired probes against vLLM)
    from maude.daemon.security import register_security_tools

    register_security_tools(mcp, audit, project)


def _register_status_tools(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    service_name: str,
    project: str,
    ctid: int,
    ip: str,
) -> None:
    """Register read-only status tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def service_status() -> str:
        """Get the systemd service status.

        Returns:
            JSON with service state, PID, memory, uptime.
        """
        result = await ssh.run(
            f"systemctl show {service_name} "
            "--property=ActiveState,SubState,MainPID,"
            "MemoryCurrent,ExecMainStartTimestamp --no-pager"
        )
        if not result.ok:
            return _format({"error": result.stderr, "service": service_name})

        props = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                props[key.strip()] = value.strip()

        return _format(
            {
                "service": service_name,
                "ctid": ctid,
                "ip": ip,
                "active_state": props.get("ActiveState", "unknown"),
                "sub_state": props.get("SubState", "unknown"),
                "pid": props.get("MainPID", "0"),
                "memory": props.get("MemoryCurrent", "0"),
                "started_at": props.get("ExecMainStartTimestamp", ""),
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def service_health() -> str:
        """Composite health check: service state + resource usage.

        Returns:
            JSON with overall health status and component checks.
        """
        checks = await gather_health_data(ssh, service_name, project, ctid)
        return _format(checks)


def _register_log_tools(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    service_name: str,
) -> None:
    """Register log access tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def service_logs(lines: int = 50, filter: str = "") -> str:
        """Get recent journal entries for the service.

        Args:
            lines: Number of lines to return. Defaults to 50. Max 500.
            filter: Optional grep filter for log content.

        Returns:
            JSON with log lines.
        """
        lines = min(lines, 500)
        cmd = f"journalctl -u {service_name} -n {lines} --no-pager -q"
        if filter:
            # Sanitize: only allow alphanumeric, spaces, dots, dashes
            safe_filter = "".join(c for c in filter if c.isalnum() or c in " .-_:")
            cmd += f" | grep -i '{safe_filter}'"

        result = await ssh.run(cmd)
        return _format(
            {
                "service": service_name,
                "lines_requested": lines,
                "filter": filter,
                "log": result.stdout.splitlines() if result.ok else [],
                "error": result.stderr if not result.ok else "",
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def service_errors(lines: int = 30, since: str = "1 hour ago") -> str:
        """Get error-level journal entries.

        Args:
            lines: Max lines to return. Defaults to 30.
            since: Time window. Defaults to "1 hour ago".

        Returns:
            JSON with error log lines.
        """
        lines = min(lines, 500)
        # Sanitize since parameter
        safe_since = "".join(c for c in since if c.isalnum() or c in " .-_:")
        cmd = f"journalctl -u {service_name} --since '{safe_since}' -p err -n {lines} --no-pager -q"
        result = await ssh.run(cmd)
        return _format(
            {
                "service": service_name,
                "since": since,
                "errors": result.stdout.splitlines() if result.ok else [],
                "error": result.stderr if not result.ok else "",
            }
        )


def _register_lifecycle_tools(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    service_name: str,
) -> None:
    """Register guarded lifecycle tools (restart, etc.)."""

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=120.0)
    async def service_restart(confirm: bool = False, reason: str = "") -> str:
        """Restart the systemd service. GUARDED: requires confirm=True and reason.

        Rate limited to once per 2 minutes. Blocked when kill switch is active.

        Args:
            confirm: Must be True to proceed.
            reason: Explanation for why the restart is needed.

        Returns:
            JSON with restart result.
        """
        result = await ssh.run(f"systemctl restart {service_name}")
        if not result.ok:
            return _format(
                {
                    "error": f"Restart failed: {result.stderr}",
                    "service": service_name,
                }
            )

        # Verify service came back
        check = await ssh.run(f"systemctl is-active {service_name}")
        return _format(
            {
                "action": "restart",
                "service": service_name,
                "reason": reason,
                "active": check.stdout == "active",
                "status": "success" if check.stdout == "active" else "failed_to_start",
            }
        )


def _register_admin_tools(mcp: Any, audit: AuditLogger, kill_switch: KillSwitch) -> None:
    """Register admin/meta tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def kill_switch_status() -> str:
        """Check if the kill switch is active (blocking write operations).

        Returns:
            JSON with kill switch state.
        """
        return _format(kill_switch.status())

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=30.0)
    async def kill_switch_activate(confirm: bool = False, reason: str = "") -> str:
        """Activate the kill switch to block all write operations.

        Args:
            confirm: Must be True.
            reason: Why the kill switch is being activated.

        Returns:
            JSON with result.
        """
        if not confirm or not reason.strip():
            return _format(
                {
                    "error": "Requires confirm=True and reason",
                }
            )
        kill_switch.activate(reason)
        return _format({"activated": True, "reason": reason})

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=30.0)
    async def kill_switch_deactivate(confirm: bool = False) -> str:
        """Deactivate the kill switch to allow write operations.

        Args:
            confirm: Must be True.

        Returns:
            JSON with result.
        """
        if not confirm:
            return _format({"error": "Requires confirm=True"})
        kill_switch.deactivate()
        return _format({"activated": False})


def _register_capacity_tools(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    service_name: str,
) -> None:
    """Register capacity management tools."""

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def service_log_cleanup(
        max_age_days: int = 7,
        max_size_mb: int = 500,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Clean up old journal logs to free disk space.

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 5 minutes. Blocked when kill switch is active.

        Args:
            max_age_days: Remove logs older than this. Defaults to 7.
            max_size_mb: Vacuum to this maximum total size. Defaults to 500MB.
            confirm: Must be True to proceed.
            reason: Explanation for the cleanup.

        Returns:
            JSON with disk usage before/after and freed space.
        """
        # Get disk usage before
        before = await ssh.run("journalctl --disk-usage")
        before_text = before.stdout.strip() if before.ok else "unknown"

        # Vacuum by time
        result = await ssh.run(
            f"journalctl --vacuum-time={max_age_days}d --vacuum-size={max_size_mb}M"
        )

        # Get disk usage after
        after = await ssh.run("journalctl --disk-usage")
        after_text = after.stdout.strip() if after.ok else "unknown"

        return _format(
            {
                "action": "log_cleanup",
                "service": service_name,
                "reason": reason,
                "max_age_days": max_age_days,
                "max_size_mb": max_size_mb,
                "before": before_text,
                "after": after_text,
                "vacuum_output": result.stdout if result.ok else result.stderr,
                "success": result.ok,
            }
        )


def _register_log_analysis_tools(
    mcp: Any,
    ssh: Any,
    audit: AuditLogger,
    service_name: str,
) -> None:
    """Register log pattern analysis tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def service_log_patterns(
        lines: int = 200,
        since: str = "1 hour ago",
        limit: int = 10,
    ) -> str:
        """Analyze recent logs for recurring patterns and error clusters.

        Extracts templates from raw log lines, groups by pattern, and
        returns the most frequent patterns with severity classification.

        Args:
            lines: Number of log lines to analyze. Defaults to 200. Max 1000.
            since: Time window for log retrieval. Defaults to "1 hour ago".
            limit: Maximum patterns to return. Defaults to 10.

        Returns:
            JSON with top log patterns, counts, and severity.
        """
        lines = min(lines, 1000)
        safe_since = "".join(c for c in since if c.isalnum() or c in " .-_:")
        cmd = f"journalctl -u {service_name} --since '{safe_since}' -n {lines} --no-pager -q"
        result = await ssh.run(cmd)
        if not result.ok:
            return _format(
                {
                    "error": result.stderr,
                    "patterns": [],
                }
            )

        log_lines = result.stdout.splitlines()

        try:
            from maude.analysis.log_analyzer import LogAnalyzer

            analyzer = LogAnalyzer()
            patterns = analyzer.top_patterns(log_lines, limit=limit)
            return _format(
                {
                    "service": service_name,
                    "lines_analyzed": len(log_lines),
                    "since": since,
                    "pattern_count": len(patterns),
                    "patterns": [
                        {
                            "template": p.template,
                            "count": p.count,
                            "severity": p.severity,
                            "examples": p.examples,
                            "first_seen": p.first_seen,
                            "last_seen": p.last_seen,
                        }
                        for p in patterns
                    ],
                }
            )
        except ImportError:
            return _format(
                {
                    "error": "LogAnalyzer not available",
                    "lines_analyzed": len(log_lines),
                    "patterns": [],
                }
            )


def _register_predictive_tools(
    mcp: Any,
    audit: AuditLogger,
    project: str,
    health_loop: Any | None,
    health_loop_ref: Any | None = None,
) -> None:
    """Register trend analysis tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def service_trends() -> str:
        """Get predictive trend data for disk, memory, and error metrics.

        Shows current values, trend direction (slope), predicted breach
        times, and anomaly scores from the Health Loop's TrendAnalyzer.

        Returns:
            JSON with per-metric trend data including predictions.
        """
        # Resolve health loop: deferred ref or direct
        hl = getattr(health_loop_ref, "_health_loop", None) if health_loop_ref else health_loop
        if hl is None:
            return _format({"error": "Health loop not running", "trends": {}})

        trends = hl.get_trends()
        metrics = ["disk_percent", "memory_percent", "recent_errors"]
        result: dict[str, Any] = {"project": project, "metrics": {}}

        for metric in metrics:
            trend = trends.get_trend(metric)
            if trend["sample_count"] == 0:
                continue
            # Add breach prediction for threshold metrics
            breach_secs = None
            thresholds = {
                "disk_percent": float(DISK_THRESHOLD_PCT),
                "memory_percent": float(MEMORY_THRESHOLD_PCT),
            }
            if metric in thresholds:
                breach_secs = trends.predict_breach(metric, thresholds[metric])

            result["metrics"][metric] = {
                **trend,
                "anomaly_score": round(trends.anomaly_score(metric), 3),
                "breach_seconds": breach_secs,
                "breach_hours": round(breach_secs / 3600, 1) if breach_secs else None,
            }

        return _format(result)
