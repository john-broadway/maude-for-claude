# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Coordination MCP Server — The Concierge
#          Claude (Anthropic) <noreply@anthropic.com>
"""Coordination MCP server — One coordination endpoint.

Runs as maude@maude.service. Provides:
- 11 standard ops tools (status, health, logs, restart, kill switch)
- 5 system-wide briefing tools (briefings, room status, dependencies, incidents)
- 4 fleet management tools (registry, memory query, restarts, deploy)
- 3 fleet deploy signal tools (repo-to-room deploy orchestration)
- 6 agency tools (department queries, routing, standards lookup)
- 2 search tools (agent knowledge + document vectors via Qdrant)
- 3 ERP tools (semantic search, record lookup, structured query)
- Real-time event listener (PG LISTEN on maude_events)
- Inter-room relay (message passing between Rooms)
- Model management (vLLM model verification)

Usage:
    python -m maude.coordination.mcp          # HTTP on :9800
    python -m maude.coordination.mcp --stdio  # stdio for Claude Code
"""

import json
import logging
import os
import re
from pathlib import Path
from typing import Any

from fastmcp import FastMCP

from maude.coordination._resources import register_fleet_resources
from maude.coordination._tools import register_briefing_tools
from maude.coordination.agency import register_agency_tools
from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.db import format_json
from maude.memory.audit import AuditLogger

try:
    from maude.coordination.erp import register_erp_tools
except ImportError:
    register_erp_tools = None  # type: ignore[assignment,misc]

try:
    from maude.coordination.fleet_deploy import (  # pyright: ignore[reportMissingImports]
        register_fleet_deploy_tools,
    )
except ImportError:
    register_fleet_deploy_tools = None  # type: ignore[assignment,misc]

try:
    from maude.coordination.site_provision import (  # pyright: ignore[reportMissingImports]
        register_site_provision_tools,
    )
except ImportError:
    register_site_provision_tools = None  # type: ignore[assignment,misc]
from maude.coordination.search import register_search_tools
from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import parse_args, setup_logging

logger = logging.getLogger(__name__)


def _get_hotel_components(
    alert_webhook_url: str = "",
) -> tuple[CrossRoomMemory, DependencyGraph, BriefingGenerator]:
    """Lazy-init shared system-wide components."""
    memory = CrossRoomMemory()
    deps = DependencyGraph()
    briefing = BriefingGenerator(memory, deps, alert_webhook_url=alert_webhook_url)
    return memory, deps, briefing


def _register_fleet_tools(
    mcp: FastMCP,
    executor: LocalExecutor,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    get_components: Any,
) -> None:
    """Register fleet deployment and management tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_room_registry() -> str:
        """List all Rooms in the hotel with their dependency relationships.

        Returns:
            JSON registry of all rooms, dependencies, and metadata.
        """
        _, deps, _ = get_components()
        rooms = deps.all_rooms
        registry = []
        for room in rooms:
            registry.append(
                {
                    "room": room,
                    "depends_on": deps.depends_on(room),
                    "depended_by": deps.depended_by(room),
                }
            )
        return json.dumps(registry, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_memory_query(
        query: str = "",
        room: str = "",
        minutes: int = 60,
    ) -> str:
        """Search memories across all Rooms.

        Args:
            query: Text to search for in memory summaries (optional).
            room: Filter to a specific room (optional).
            minutes: Lookback window in minutes. Defaults to 60.

        Returns:
            JSON list of matching memories.
        """
        memory, _, _ = get_components()
        activity = await memory.recent_activity(minutes=minutes)
        if room:
            activity = [a for a in activity if a.get("project") == room]
        if query:
            query_lower = query.lower()
            activity = [a for a in activity if query_lower in (a.get("summary") or "").lower()]
        return format_json(activity[:50])

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_recent_restarts(minutes: int = 60) -> str:
        """Get recent auto-restart events across all Rooms.

        Args:
            minutes: Lookback window in minutes. Defaults to 60.

        Returns:
            JSON list of restart events from the audit log.
        """
        memory, _, _ = get_components()
        restarts = await memory.recent_restarts(minutes=minutes)
        return format_json(restarts)

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def fleet_deploy(
        scope: str = "all",
        dry_run: bool = True,
        skip_restart: bool = False,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Deploy the maude library to Rooms via deploy-fleet.sh.

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 5 minutes. dry_run=True by default for safety.

        Args:
            scope: "all", phase number ("1", "2", "3"), or room name.
            dry_run: Preview only — no changes. Defaults to True.
            skip_restart: Deploy code without restarting services.
            confirm: Must be True to proceed.
            reason: Explanation for the deployment.

        Returns:
            JSON with deployment result or dry-run preview.
        """
        if not re.match(r"^[a-zA-Z0-9_-]+$", scope):
            return json.dumps(
                {
                    "error": f"Invalid scope: {scope!r}"
                    " — must be alphanumeric, hyphens,"
                    " or underscores only",
                },
                indent=2,
            )

        script = "/app/maude/scripts/deploy-fleet.sh"
        cmd_parts = ["bash", script]
        if dry_run:
            cmd_parts.append("--dry-run")
        if skip_restart:
            cmd_parts.append("--skip-restart")

        if scope in ("1", "2", "3", "all"):
            cmd_parts.extend(["--phase", scope])
        elif scope != "all":
            cmd_parts.extend(["--room", scope])

        cmd = " ".join(cmd_parts)

        result = await executor.run(cmd)
        return json.dumps(
            {
                "action": "fleet_deploy",
                "scope": scope,
                "dry_run": dry_run,
                "skip_restart": skip_restart,
                "reason": reason,
                "exit_code": 0 if result.ok else 1,
                "stdout": result.stdout,
                "stderr": result.stderr,
            },
            indent=2,
        )


def _register_event_tools(
    mcp: FastMCP,
    audit: AuditLogger,
    lifecycle_refs: dict[str, Any],
) -> None:
    """Register real-time event stream tools.

    Tools use lifecycle_refs["event_listener"] which is set during startup.
    """

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_live_events(
        limit: int = 50,
        room: str = "",
        event_type: str = "",
    ) -> str:
        """Recent real-time events from all Rooms (from PG LISTEN buffer).

        Events are received in real-time via PostgreSQL LISTEN/NOTIFY.
        The buffer holds the last 500 events.

        Args:
            limit: Maximum events to return. Defaults to 50.
            room: Filter to a specific room name (optional).
            event_type: Filter to a specific event type (optional).

        Returns:
            JSON list of recent events.
        """
        listener = lifecycle_refs.get("event_listener")
        if listener is None:
            return json.dumps(
                {
                    "error": "EventListener not running",
                    "events": [],
                },
                indent=2,
            )
        events = listener.recent_events(limit=limit)
        if room:
            events = [e for e in events if e.get("project") == room]
        if event_type:
            events = [e for e in events if e.get("event_type") == event_type]
        return format_json({"events": events[:limit]})


def _register_relay_tools(mcp: FastMCP, audit: AuditLogger) -> None:
    """Register inter-room relay tools — 4 new task-state + 2 legacy wrappers."""
    from maude.coordination.relay import Relay

    relay = Relay()

    # ── New task-state tools ───────────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=6.0)
    async def relay_send(
        to_room: str,
        subject: str,
        body: str,
        priority: int = 0,
    ) -> str:
        """Create a relay task in pending status.

        Args:
            to_room: Destination room name.
            subject: Brief subject line.
            body: Task body / message.
            priority: Priority level (0=normal, higher=more urgent).

        Returns:
            JSON with task ID and status.
        """
        from_room = "coordinator"
        try:
            task_id = await relay.send(from_room, to_room, subject, body, priority)
            return json.dumps(
                {
                    "task_id": task_id,
                    "from_room": from_room,
                    "to_room": to_room,
                    "subject": subject,
                    "status": "pending",
                },
                indent=2,
            )
        except Exception as e:
            return json.dumps({"error": str(e)}, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def relay_accept(task_id: int, room: str) -> str:
        """Accept a relay task (pending → accepted).

        Args:
            task_id: The relay task ID.
            room: The room accepting the task.

        Returns:
            JSON with updated task state.
        """
        try:
            task = await relay.accept(task_id, room)
            return format_json(task.to_dict())
        except (ValueError, Exception) as e:
            return json.dumps({"error": str(e)}, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def relay_update(
        task_id: int,
        room: str,
        status: str,
        result: str = "",
    ) -> str:
        """Update a relay task status (running, completed, failed, cancelled).

        Args:
            task_id: The relay task ID.
            room: The room updating the task.
            status: Target status.
            result: Result text (for completed/failed).

        Returns:
            JSON with updated task state.
        """
        try:
            task = await relay.update(task_id, room, status, result)
            return format_json(task.to_dict())
        except (ValueError, Exception) as e:
            return json.dumps({"error": str(e)}, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def relay_tasks(
        room: str = "",
        status: str = "",
        from_room: str = "",
        limit: int = 20,
        since_minutes: int = 0,
    ) -> str:
        """Query relay tasks with filters.

        Args:
            room: Filter by destination room.
            status: Filter by status (pending, accepted, running, completed, failed, cancelled).
            from_room: Filter by source room.
            limit: Maximum results. Defaults to 20.
            since_minutes: Only tasks from last N minutes. 0 = no limit.

        Returns:
            JSON list of relay tasks.
        """
        try:
            tasks = await relay.tasks(
                room=room,
                status=status,
                from_room=from_room,
                limit=limit,
                since_minutes=since_minutes,
            )
            return format_json([t.to_dict() for t in tasks])
        except Exception as e:
            return json.dumps({"error": str(e), "tasks": []}, indent=2)

    # ── Legacy wrapper tools (backward compat) ─────────────────────

    @mcp.tool()
    @audit_logged(audit)
    @rate_limited(min_interval_seconds=6.0)
    async def coordinator_relay(
        to_room: str,
        subject: str,
        body: str,
    ) -> str:
        """Send a message from one Room to another via the Coordinator relay.

        Legacy wrapper — calls relay_send internally.

        Args:
            to_room: Destination room name.
            subject: Brief subject line.
            body: Message body.

        Returns:
            JSON with message ID and status.
        """
        from_room = "coordinator"
        try:
            msg_id = await relay.send(from_room, to_room, subject, body)
            return json.dumps(
                {
                    "id": msg_id,
                    "from": from_room,
                    "to": to_room,
                    "subject": subject,
                    "status": "delivered",
                },
                indent=2,
            )
        except Exception as e:
            return json.dumps({"error": str(e)}, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_messages(
        room: str,
        limit: int = 20,
        since_minutes: int = 60,
    ) -> str:
        """Check a Room's message inbox.

        Legacy wrapper — calls relay.inbox() internally.

        Args:
            room: Room name to check inbox for.
            limit: Maximum messages to return. Defaults to 20.
            since_minutes: Lookback window in minutes. Defaults to 60.

        Returns:
            JSON list of messages.
        """
        try:
            messages = await relay.inbox(room, limit=limit, since_minutes=since_minutes)
            return format_json({"room": room, "messages": messages})
        except Exception as e:
            return json.dumps(
                {
                    "room": room,
                    "error": str(e),
                    "messages": [],
                },
                indent=2,
            )


def _register_model_tools(
    mcp: FastMCP,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    get_components: Any,
) -> None:
    """Register vLLM model management tools."""

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=120.0)
    async def coordinator_rebuild_models(
        room: str = "",
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Verify per-Room system prompts and vLLM model availability.

        With vLLM, system prompts are passed at runtime (not baked into models).
        This tool regenerates system prompts from knowledge files and verifies
        the base model is loaded on vLLM.
        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 2 minutes.

        Args:
            room: Single room to verify, or empty for all rooms.
            confirm: Must be True to proceed.
            reason: Explanation for the verification.

        Returns:
            JSON with verification results per room.
        """
        from maude.healing.model_manager import (
            VLLMModelManager,
            generate_system_prompt,
            resolve_knowledge_path,
        )

        _, deps, _ = get_components()
        mgr = VLLMModelManager()
        results: list[dict[str, Any]] = []

        rooms = [room] if room else deps.all_rooms
        for r in rooms:
            model_cfg = deps.model_for(r)
            if not model_cfg:
                results.append({"room": r, "status": "skipped", "reason": "no model config"})
                continue

            name = model_cfg["name"]
            base = model_cfg.get("base", "Qwen/Qwen3-8B")
            knowledge_path = resolve_knowledge_path(r)

            system = generate_system_prompt(r, knowledge_path)
            model_loaded = await mgr.model_exists(base)
            results.append(
                {
                    "room": r,
                    "model": name,
                    "base_model": base,
                    "base_loaded": model_loaded,
                    "system_prompt_len": len(system),
                    "status": "ok" if model_loaded else "base_model_not_loaded",
                }
            )

        await mgr.close()
        return json.dumps(
            {
                "action": "verify_models",
                "reason": reason,
                "results": results,
            },
            indent=2,
        )


def _register_training_tools(
    mcp: FastMCP,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    lifecycle_refs: dict[str, Any],
) -> None:
    """Register self-learning training pipeline tools.

    Tools use lifecycle_refs["training_loop"] which is set during startup
    by the lifecycle manager. Returns graceful errors if the loop hasn't
    started yet.
    """

    @mcp.tool()
    @audit_logged(audit)
    async def training_status() -> str:
        """Current training pipeline status and recent training runs.

        Returns:
            JSON with current stage, config, and last 5 training runs.
        """
        loop = lifecycle_refs.get("training_loop")
        if loop is None:
            return json.dumps({"enabled": False, "stage": "not_initialized"})
        status = loop.current_status()
        history = await loop.training_history(limit=5)
        return json.dumps(
            {
                "enabled": True,
                **status,
                "recent_runs": history,
            },
            indent=2,
            default=str,
        )

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=3600.0)
    async def training_trigger(
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Manually trigger a training pipeline run.

        GUARDED: requires confirm=True and reason. Rate-limited to once per hour.

        Args:
            confirm: Must be True to proceed.
            reason: Explanation for the manual trigger.

        Returns:
            JSON with training run result or error.
        """
        loop = lifecycle_refs.get("training_loop")
        if loop is None:
            return json.dumps({"error": "Training loop not initialized"})
        result = await loop.trigger_manual()
        return json.dumps(
            {
                "action": "training_trigger",
                "reason": reason,
                **result,
            },
            indent=2,
            default=str,
        )


def _register_promotion_tools(
    mcp: FastMCP,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    lifecycle_refs: dict[str, Any],
) -> None:
    """Register model promotion lifecycle tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def training_model_status(project: str = "") -> str:
        """Active or canary model for a project.

        Shows model name, A/B ratio, autonomy baseline vs current.

        Args:
            project: Project name. Defaults to this server's project.

        Returns:
            JSON with active promotion details, or null if none.
        """
        promoter = lifecycle_refs.get("promoter")
        if not promoter:
            return json.dumps({"error": "Promoter not initialized"})
        active = await promoter.get_active(project or "coordinator")
        return json.dumps(active, indent=2, default=str)

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    async def training_promote(
        version: int,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Manually promote a validated model to full traffic (ratio=1.0).

        GUARDED: requires confirm=True and reason.

        Args:
            version: Training run version to promote.
            confirm: Must be True to proceed.
            reason: Explanation for the manual promotion.

        Returns:
            JSON with promotion result.
        """
        promoter = lifecycle_refs.get("promoter")
        if not promoter:
            return json.dumps({"error": "Promoter not initialized"})
        project = "coordinator"
        await promoter.promote(project, version)
        active = await promoter.get_active(project)
        return json.dumps(
            {"action": "promoted", "version": version, "reason": reason, "active": active},
            indent=2,
            default=str,
        )

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    async def training_rollback(
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Rollback to base model. Sets challenger_ratio=0.

        GUARDED: requires confirm=True and reason.

        Args:
            confirm: Must be True to proceed.
            reason: Explanation for the rollback.

        Returns:
            JSON with rollback result.
        """
        promoter = lifecycle_refs.get("promoter")
        if not promoter:
            return json.dumps({"error": "Promoter not initialized"})
        project = "coordinator"
        await promoter.rollback(project)
        return json.dumps(
            {"action": "rolled_back", "reason": reason},
            indent=2,
        )


def _register_autonomy_tools(mcp: FastMCP, audit: AuditLogger) -> None:
    """Register fleet autonomy scoring tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_autonomy_scores(hours: int = 24) -> str:
        """Compute autonomy scores for all Rooms over the last N hours.

        Args:
            hours: Lookback window in hours. Defaults to 24.

        Returns:
            JSON with per-room autonomy scores.
        """
        try:
            from maude.coordination.autonomy_metrics import AutonomyMetrics

            metrics = AutonomyMetrics()
            try:
                scores = await metrics.fleet_scores(hours=hours)
                return json.dumps(
                    {
                        "hours": hours,
                        "room_count": len(scores),
                        "scores": scores,
                    },
                    indent=2,
                    default=str,
                )
            finally:
                await metrics.close()
        except Exception as e:
            return json.dumps({"error": str(e), "scores": []}, indent=2)

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_autonomy_trends(days: int = 7) -> str:
        """Get daily autonomy score trends from stored snapshots.

        Args:
            days: Number of days to look back. Defaults to 7.

        Returns:
            JSON with daily autonomy snapshots per room.
        """
        try:
            from maude.coordination.autonomy_metrics import AutonomyMetrics

            metrics = AutonomyMetrics()
            try:
                trends = await metrics.get_trends(days=days)
                return json.dumps(
                    {
                        "days": days,
                        "trends": trends,
                    },
                    indent=2,
                    default=str,
                )
            finally:
                await metrics.close()
        except Exception as e:
            return json.dumps({"error": str(e), "trends": []}, indent=2)


def _register_correlation_tools(
    mcp: FastMCP,
    audit: AuditLogger,
    lifecycle_refs: dict[str, Any],
) -> None:
    """Register cross-room incident correlation tools.

    Uses the CorrelationEngine attached to the EventListener (via lifecycle_refs).
    """

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_correlated_incidents(limit: int = 20) -> str:
        """Get recent correlated incidents detected by the Correlation Engine.

        Args:
            limit: Maximum incidents to return. Defaults to 20.

        Returns:
            JSON with correlated incidents including root room and affected rooms.
        """
        listener = lifecycle_refs.get("event_listener")
        if listener is None or getattr(listener, "_correlation", None) is None:
            return json.dumps(
                {
                    "error": "Correlation engine not running (event listener inactive)",
                    "incidents": [],
                },
                indent=2,
            )
        incidents = listener._correlation.recent_correlations(limit=limit)
        return json.dumps(
            {
                "incidents": [
                    {
                        "id": inc.id,
                        "root_room": inc.root_room,
                        "affected_rooms": inc.affected_rooms,
                        "event_type": inc.event_type,
                        "timestamp": inc.timestamp.isoformat(),
                        "correlation_score": inc.correlation_score,
                        "resolved": inc.resolved,
                    }
                    for inc in incidents
                ],
            },
            indent=2,
        )


def _register_diagnostic_tools(mcp: FastMCP, audit: AuditLogger, get_components: Any) -> None:
    """Register data pipeline and dependency chain trace tools."""

    async def _http_health_checker(room: str) -> dict[str, Any]:
        """Probe a room's service port via TCP connect."""
        import asyncio
        import time

        _, deps, _ = get_components()
        room_data = deps._rooms.get(room, {})
        ip = room_data.get("ip", "")
        port = room_data.get("service_port")
        if not ip or not port:
            return {"status": "skipped", "detail": "No IP/port in dependency graph"}
        t0 = time.monotonic()
        try:
            _, writer = await asyncio.wait_for(
                asyncio.open_connection(ip, port),
                timeout=5.0,
            )
            writer.close()
            await writer.wait_closed()
            latency = (time.monotonic() - t0) * 1000
            return {
                "status": "healthy",
                "detail": f"TCP port {port} open",
                "latency_ms": round(latency, 1),
            }
        except (TimeoutError, OSError) as e:
            latency = (time.monotonic() - t0) * 1000
            return {
                "status": "unhealthy",
                "detail": str(e),
                "latency_ms": round(latency, 1),
            }

    @mcp.tool()
    @audit_logged(audit)
    async def coordinator_diagnostic_trace(
        pipeline: str = "plc_to_monitoring",
        mode: str = "pipeline",
    ) -> str:
        """Trace a data pipeline or dependency chain across rooms.

        Modes:
        - "pipeline": Trace a named data pipeline (plc_to_monitoring,
          plc_to_dashboard, metrics, logs) or custom comma-separated rooms.
        - "dependency": Trace all upstream dependencies for a room.

        Args:
            pipeline: Pipeline name or room name (for dependency mode).
            mode: "pipeline" or "dependency". Defaults to "pipeline".

        Returns:
            JSON with per-hop status, broken_at indicator, and overall health.
        """
        from maude.coordination.diagnostic_trace import DiagnosticTracer

        _, deps, _ = get_components()
        tracer = DiagnosticTracer(deps, health_checker=_http_health_checker)

        if mode == "dependency":
            result = await tracer.trace_dependency_chain(pipeline)
        else:
            result = await tracer.trace_data_pipeline(pipeline)

        return json.dumps(
            {
                "name": result.name,
                "healthy": result.healthy,
                "broken_at": result.broken_at,
                "timestamp": result.timestamp.isoformat(),
                "hops": [
                    {
                        "room": hop.room,
                        "status": hop.status,
                        "detail": hop.detail,
                        "latency_ms": hop.latency_ms,
                        "metadata": hop.metadata,
                    }
                    for hop in result.hops
                ],
                "available_pipelines": tracer.available_pipelines,
            },
            indent=2,
        )


def _register_evaluation_tools(mcp: FastMCP, audit: AuditLogger, kill_switch: KillSwitch) -> None:
    """Register model evaluation and benchmarking tools."""

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_model_evaluation(
        model: str = "",
        test_limit: int = 50,
    ) -> str:
        """Run an evaluation benchmark against a candidate model.

        Args:
            model: Model name to evaluate (e.g., "qwen3:8b"). Required.
            test_limit: Maximum test conversations to evaluate. Defaults to 50.

        Returns:
            JSON with benchmark scores and pass rate.
        """
        if not model:
            return json.dumps({"error": "model parameter is required"}, indent=2)

        try:
            import asyncpg

            from maude.daemon.common import pg_pool_kwargs
            from maude.eval.benchmark import create_test_set, run_benchmark

            kwargs = pg_pool_kwargs(database="agent", min_size=1, max_size=3)
            pool = await asyncpg.create_pool(**kwargs)
            try:
                test_set = await create_test_set(pool, limit=test_limit)
                if not test_set:
                    return json.dumps(
                        {
                            "error": "No test conversations available",
                            "model": model,
                        },
                        indent=2,
                    )

                result = await run_benchmark(model, test_set)
                return json.dumps(
                    {
                        "model": result.model,
                        "test_count": result.test_count,
                        "avg_score": round(result.avg_score, 3),
                        "pass_rate": round(result.pass_rate, 3),
                        "tool_selection": round(result.tool_selection_avg, 3),
                        "diagnosis": round(result.diagnosis_avg, 3),
                        "structured_output": round(result.structured_output_avg, 3),
                        "noop_recognition": round(result.noop_recognition_avg, 3),
                        "escalation_calibration": round(result.escalation_calibration_avg, 3),
                        "duration_seconds": round(result.duration_seconds, 1),
                    },
                    indent=2,
                )
            finally:
                await pool.close()
        except Exception as e:
            return json.dumps(
                {
                    "error": str(e),
                    "model": model,
                },
                indent=2,
            )


def create_server(
    config: RoomConfig,
    lifecycle_refs: dict[str, Any] | None = None,
) -> FastMCP:
    """Create the Coordination MCP server from config.

    Args:
        config: Room configuration.
        lifecycle_refs: Mutable dict for late-binding background task
            instances (training_loop, event_listener). Set by the
            lifecycle manager during startup.
    """
    if lifecycle_refs is None:
        lifecycle_refs = {}
    mcp = FastMCP(
        name="Maude Coordination MCP",
        instructions=(
            f"MCP server for the maude service "
            f"(CTID {config.ctid}, {config.ip}). "
            f"Maude Coordination — system-wide coordination, "
            f"fleet deployment, cross-room memory, organizational "
            f"intelligence (department agents), and semantic search. "
            f"{config.description}"
        ),
    )
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    # 11 standard ops tools
    register_ops_tools(
        mcp,
        executor,
        audit,
        kill_switch,
        config.service_name,
        config.project,
        ctid=config.ctid,
        ip=config.ip,
    )

    # Hotel components (lazy-init)
    alerting_cfg = dict(config.raw.get("alerting") or {})
    alert_webhook_url = alerting_cfg.get("webhook_url", "")
    components = _get_hotel_components(alert_webhook_url=alert_webhook_url)
    get_components = lambda: components  # noqa: E731

    # Hotel-wide briefing tools (6)
    register_briefing_tools(mcp, audit, lambda: components)

    # Fleet resources (3 read-only MCP Resources)
    register_fleet_resources(mcp, get_components)

    # Fleet management tools (4)
    _register_fleet_tools(mcp, executor, audit, kill_switch, get_components)

    # Fleet deploy signal tools (3) — repo-to-room deploy orchestration
    if register_fleet_deploy_tools is not None:
        register_fleet_deploy_tools(mcp, audit, kill_switch, get_components)

    # Site provisioning tools (3) — sovereign room provisioning from this Maude
    if register_site_provision_tools is not None:
        register_site_provision_tools(mcp, audit, kill_switch, config)

    # Event stream tools (1) — live when lifecycle starts event listener
    _register_event_tools(mcp, audit, lifecycle_refs)

    # Relay tools (2) — wired to Relay class (lazy PG pool)
    _register_relay_tools(mcp, audit)

    # Model management tools (1)
    _register_model_tools(mcp, audit, kill_switch, get_components)

    # Training tools (2) — live when lifecycle starts training loop
    _register_training_tools(mcp, audit, kill_switch, lifecycle_refs)

    # Model promotion tools (3) — canary lifecycle, promote, rollback
    _register_promotion_tools(mcp, audit, kill_switch, lifecycle_refs)

    # Autonomy metrics tools (2)
    _register_autonomy_tools(mcp, audit)

    # Correlation tools (1) — live when lifecycle starts event listener
    _register_correlation_tools(mcp, audit, lifecycle_refs)

    # Diagnostic trace tools (1) — wired to TCP health checker
    _register_diagnostic_tools(mcp, audit, get_components)

    # Evaluation tools (1)
    _register_evaluation_tools(mcp, audit, kill_switch)

    # Agency tools (6) — organizational intelligence
    agency_root = Path(os.environ.get("AGENCY_ROOT", "/app/agency"))
    register_agency_tools(mcp, audit, agency_root)

    # Search tools (2) — semantic search
    register_search_tools(mcp, audit)

    # ERP tools (3) — semantic + structured search over ERP records
    # Config from YAML, with env var fallback for API credentials
    erp_cfg = dict(config.raw.get("erp") or {})
    if not erp_cfg.get("api_key") and os.environ.get("MAUDE_ERP_API_KEY"):
        erp_cfg["api_key"] = os.environ["MAUDE_ERP_API_KEY"]
        erp_cfg["api_secret"] = os.environ.get("MAUDE_ERP_API_SECRET", "")
    if register_erp_tools is not None:
        register_erp_tools(mcp, audit, erp_cfg)

    return mcp


def main() -> None:
    """Run the Coordination MCP server.

    Uses custom main() instead of run_room() because the Coordinator:
    1. Binds to 0.0.0.0 (accessible from all rooms)
    2. Starts additional background tasks (training loop, event listener)
    """
    import asyncio

    from maude.healing.lifecycle import run_with_lifecycle

    args = parse_args(default_config=str(Path(__file__).parent / "config.yaml"))
    setup_logging(args.log_level)

    config = RoomConfig.from_yaml(args.config)
    port = args.port or config.mcp_port

    logger.info(
        "Starting coordinator room (CTID %d, port %d, transport %s)",
        config.ctid,
        port,
        args.transport,
    )

    # Lifecycle refs: mutable dict for late-binding background task instances.
    # Training tools read from this dict; lifecycle populates it during startup.
    lifecycle_refs: dict[str, Any] = {}
    mcp = create_server(config, lifecycle_refs=lifecycle_refs)

    # For stdio transport, skip lifecycle (Claude Code MCP session)
    if args.transport == "stdio":
        mcp.run(transport="stdio")
        return

    # Coordinator extra lifecycle: training loop + event listener + consolidator
    async def _extra_startup() -> None:
        # Event listener (PG LISTEN for cross-room events) + relay injection
        try:
            from maude.coordination.event_listener import EventListener
            from maude.coordination.relay import Relay

            _, deps, _ = _get_hotel_components()
            relay = Relay()
            event_listener = EventListener(dependency_graph=deps, relay=relay)
            await event_listener.start()
            lifecycle_refs["event_listener"] = event_listener
            logger.info("EventListener started for coordinator")
        except Exception:
            logger.warning("EventListener failed to start (non-fatal)")

        # Memory consolidation background task (6h interval)
        try:
            from maude.memory.consolidation import MemoryConsolidator

            async def _run_consolidation() -> None:
                while True:
                    try:
                        consolidator = MemoryConsolidator()
                        try:
                            await consolidator.consolidate_all()
                        finally:
                            await consolidator.close()
                    except Exception:
                        logger.warning(
                            "MemoryConsolidator run failed (non-fatal)",
                            exc_info=True,
                        )
                    await asyncio.sleep(21600)

            consolidation_task = asyncio.create_task(_run_consolidation())
            lifecycle_refs["consolidation_task"] = consolidation_task
            logger.info("MemoryConsolidator background task started (6h interval)")
        except Exception:
            logger.warning("MemoryConsolidator failed to start (non-fatal)")

        # Training loop (self-learning pipeline)
        if config.training_loop and config.training_loop.get("enabled"):
            try:
                from maude.healing.training.loop import TrainingLoop, TrainingLoopConfig
                from maude.healing.training.promoter import ModelPromoter

                tc = TrainingLoopConfig.from_dict(config.training_loop)
                audit = AuditLogger(project=config.project)
                training_loop = TrainingLoop(
                    audit=audit,
                    config=tc,
                )

                # Model promoter — canary deployment lifecycle
                promoter = ModelPromoter()
                lifecycle_refs["promoter"] = promoter

                # Wire completion callback: training → canary deployment
                async def _on_training_complete(state):
                    p = lifecycle_refs.get("promoter")
                    if not p or not state.validation_passed:
                        return
                    try:
                        from maude.coordination.autonomy_metrics import AutonomyMetrics

                        metrics = AutonomyMetrics()
                        try:
                            baseline = await metrics.room_score(config.project, hours=24)
                            await p.start_canary(
                                project=config.project,
                                training_run_id=state.run_id,
                                model_name=state.model_name,
                                validation_score=state.validation_score or 0.0,
                                baseline_autonomy=baseline.get("autonomy_score", 0.0),
                            )
                        finally:
                            await metrics.close()
                    except Exception:
                        logger.warning(
                            "Post-training canary start failed (non-fatal)",
                            exc_info=True,
                        )

                training_loop.set_completion_callback(_on_training_complete)

                await training_loop.start()
                lifecycle_refs["training_loop"] = training_loop
                logger.info("TrainingLoop started for coordinator (promoter wired)")
            except Exception:
                logger.warning("TrainingLoop failed to start (non-fatal)")

        # Canary evaluation background loop (checks every 6h)
        if lifecycle_refs.get("promoter"):
            try:

                async def _canary_eval_loop() -> None:
                    await asyncio.sleep(21600)  # first eval after 6h
                    while True:
                        try:
                            p = lifecycle_refs.get("promoter")
                            if not p:
                                break
                            canaries = await p.list_active_canaries()
                            for project in canaries:
                                try:
                                    from maude.coordination.autonomy_metrics import (
                                        AutonomyMetrics,
                                    )

                                    metrics = AutonomyMetrics()
                                    try:
                                        score = await metrics.room_score(project, hours=24)
                                        result = await p.evaluate_canary(
                                            project, score.get("autonomy_score", 0.0)
                                        )
                                        logger.info(
                                            "Canary eval for %s: %s", project, result.get("action")
                                        )
                                    finally:
                                        await metrics.close()
                                except Exception:
                                    logger.warning("Canary eval failed for %s (non-fatal)", project)
                        except Exception:
                            logger.warning("Canary eval loop error (non-fatal)", exc_info=True)
                        await asyncio.sleep(21600)

                canary_task = asyncio.create_task(_canary_eval_loop())
                lifecycle_refs["canary_eval_task"] = canary_task
                logger.info("Canary evaluation loop started (6h interval)")
            except Exception:
                logger.warning("Canary eval loop failed to start (non-fatal)")

    async def _extra_shutdown() -> None:
        consolidation_task = lifecycle_refs.get("consolidation_task")
        if consolidation_task:
            consolidation_task.cancel()
            try:
                await consolidation_task
            except asyncio.CancelledError:
                pass
            logger.info("MemoryConsolidator task stopped")
        canary_task = lifecycle_refs.get("canary_eval_task")
        if canary_task:
            canary_task.cancel()
            try:
                await canary_task
            except asyncio.CancelledError:
                pass
            logger.info("Canary eval loop stopped")
        training_loop = lifecycle_refs.get("training_loop")
        if training_loop:
            await training_loop.stop()
            logger.info("TrainingLoop stopped")
        promoter = lifecycle_refs.get("promoter")
        if promoter:
            await promoter.close()
            logger.info("ModelPromoter stopped")
        event_listener = lifecycle_refs.get("event_listener")
        if event_listener:
            await event_listener.stop()
            logger.info("EventListener stopped")

    asyncio.run(
        run_with_lifecycle(
            mcp,
            config,
            transport=args.transport,
            host="0.0.0.0",
            port=port,
            extra_startup=_extra_startup,
            extra_shutdown=_extra_shutdown,
        )
    )


if __name__ == "__main__":
    main()
