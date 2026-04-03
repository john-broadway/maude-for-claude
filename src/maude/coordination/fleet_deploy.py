# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Fleet deployment orchestration for the Maude Coordinator.

Signals rooms to self-deploy by publishing events and relay messages.
Maps git repositories to rooms using the dependency graph's project field.
Includes fleet_local_deploy for Maude-side maude library distribution
to local rooms (same subnet, no cross-site SSH).

         Claude (Anthropic) <noreply@anthropic.com>

Usage:
    from maude.coordination.fleet_deploy import register_fleet_deploy_tools
    register_fleet_deploy_tools(mcp, audit, kill_switch, get_components)
"""

import asyncio
import json
import logging
import time
from typing import Any

from maude.coordination.dependencies import DependencyGraph
from maude.daemon.executor import LocalExecutor
from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.db import LazyPool, format_json
from maude.memory.audit import AuditLogger

logger = logging.getLogger(__name__)

MAUDE_REPO = "maude"


def repo_to_rooms(deps: DependencyGraph, repo: str, site: str = "") -> list[dict[str, Any]]:
    """Map a git repository path to the rooms that use it.

    Args:
        deps: DependencyGraph instance.
        repo: Repo path like "infrastructure/postgresql" or "maude".
        site: Optional site filter ("site-a", "site-b"). Empty = all sites.

    Returns:
        List of dicts with room name, site, ip, mcp_port for each matching room.
    """
    matches: list[dict[str, Any]] = []

    for qualified_name in deps.all_rooms:
        meta = deps.room_info(qualified_name)
        room_project = meta.get("project", "")
        room_site = meta.get("site", "")

        # For maude repo, ALL rooms need the library update
        if repo == MAUDE_REPO:
            pass  # every room matches
        elif room_project != repo:
            continue

        if site and room_site != site:
            continue

        # Extract bare room name from "site-a/postgresql" -> "postgresql"
        bare_name = qualified_name.split("/", 1)[-1] if "/" in qualified_name else qualified_name

        matches.append(
            {
                "room": bare_name,
                "qualified": qualified_name,
                "site": room_site,
                "ip": meta.get("ip", ""),
                "mcp_port": meta.get("mcp_port", 0),
            }
        )

    return matches


def register_fleet_deploy_tools(
    mcp: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    get_components: Any,
    *,
    publisher: Any = None,
    relay: Any = None,
) -> None:
    """Register fleet deploy signal and status tools.

    Args:
        mcp: FastMCP server instance.
        audit: AuditLogger for recording tool calls.
        kill_switch: KillSwitch for guarding mutating operations.
        get_components: Callable returning (memory, deps, briefing).
        publisher: Optional EventPublisher override (for testing).
        relay: Optional Relay override (for testing).
    """
    # Lazy-initialized publisher and relay (created on first use)
    _publisher_ref: dict[str, Any] = {}
    _relay_ref: dict[str, Any] = {}
    _pool_ref: dict[str, Any] = {}

    if publisher is not None:
        _publisher_ref["publisher"] = publisher
    if relay is not None:
        _relay_ref["relay"] = relay

    async def _get_publisher() -> Any:
        if "publisher" not in _publisher_ref:
            from maude.infra.events import EventPublisher

            pub = EventPublisher(project="coordinator")
            await pub.connect()
            _publisher_ref["publisher"] = pub
        return _publisher_ref["publisher"]

    async def _get_relay() -> Any:
        if "relay" not in _relay_ref:
            from maude.coordination.relay import Relay

            _relay_ref["relay"] = Relay()
        return _relay_ref["relay"]

    async def _get_pool() -> LazyPool:
        if "pool" not in _pool_ref:
            _pool_ref["pool"] = LazyPool(database="agent")
        return _pool_ref["pool"]

    async def _verify_deploys(targets: list[dict[str, Any]]) -> None:
        """Check health endpoints ~30s after deploy signals are sent."""
        await asyncio.sleep(30)
        try:
            import httpx
        except ImportError:
            logger.debug("httpx not available — skipping deploy verification")
            return

        for target in targets:
            ip = target.get("ip", "")
            port = target.get("mcp_port", 0)
            if not ip or not port:
                continue
            url = f"http://{ip}:{port}/health"
            try:
                async with httpx.AsyncClient(timeout=10.0) as client:
                    resp = await client.get(url)
                if resp.status_code != 200:
                    logger.warning(
                        "Deploy verify: %s returned HTTP %d at %s",
                        target["room"],
                        resp.status_code,
                        url,
                    )
            except Exception as exc:
                logger.warning(
                    "Deploy verify: %s unreachable at %s after deploy: %s",
                    target["room"],
                    url,
                    exc,
                )

    async def _signal_rooms(
        repo: str,
        targets: list[dict[str, Any]],
        action: str,
        reason: str,
    ) -> list[dict[str, Any]]:
        """Publish event + relay message to each target room."""
        publisher = await _get_publisher()
        relay = await _get_relay()
        signals: list[dict[str, Any]] = []

        for target in targets:
            room_name = target["room"]
            event_ok = await publisher.publish(
                "deploy_requested",
                {
                    "repo": repo,
                    "target_room": room_name,
                    "action": action,
                    "reason": reason,
                },
            )

            relay_ok = False
            try:
                await relay.send(
                    "coordinator",
                    room_name,
                    "Deploy Signal",
                    f"New code available in {repo}. Please {action.replace('_', ' ')}.",
                )
                relay_ok = True
            except Exception:
                logger.warning("Relay send failed for %s (non-fatal)", room_name)

            signals.append(
                {
                    "room": room_name,
                    "site": target.get("site", ""),
                    "event": event_ok,
                    "relay": relay_ok,
                }
            )

        return signals

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=60.0)
    async def fleet_deploy_signal(
        repo: str,
        site: str = "",
        rooms: str = "",
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Signal rooms to self-deploy their application code.

        Publishes deploy_requested events and sends relay messages to
        targeted rooms. Rooms are resolved from the dependency graph's
        project field.

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 60 seconds.

        Args:
            repo: Git repository path (e.g., "infrastructure/postgresql"). Required.
            site: Site filter ("site-a", "site-b", ""). Default empty = all sites.
            rooms: Comma-separated room names to target. Empty = all rooms using this repo.
            confirm: Must be True to proceed.
            reason: Why the deploy is happening.

        Returns:
            JSON summary of signals sent.
        """
        _, deps, _ = get_components()
        action = "self_update" if repo == MAUDE_REPO else "self_deploy"

        if rooms:
            # Parse explicit room list
            room_names = [r.strip() for r in rooms.split(",") if r.strip()]
            targets = []
            for name in room_names:
                qualified = deps.resolve(name)
                if qualified:
                    meta = deps.room_info(qualified)
                    bare = qualified.split("/", 1)[-1] if "/" in qualified else qualified
                    if site and meta.get("site", "") != site:
                        continue
                    targets.append(
                        {
                            "room": bare,
                            "qualified": qualified,
                            "site": meta.get("site", ""),
                            "ip": meta.get("ip", ""),
                            "mcp_port": meta.get("mcp_port", 0),
                        }
                    )
        else:
            targets = repo_to_rooms(deps, repo, site=site)

        if not targets:
            return json.dumps(
                {
                    "action": "fleet_deploy_signal",
                    "repo": repo,
                    "site": site,
                    "reason": reason,
                    "error": (
                        f"No rooms found for repo '{repo}'" + (f" at site '{site}'" if site else "")
                    ),
                    "signals_sent": [],
                    "total": 0,
                    "status": "no_targets",
                },
                indent=2,
            )

        signals = await _signal_rooms(repo, targets, action, reason)
        asyncio.create_task(_verify_deploys(targets))

        return json.dumps(
            {
                "action": "fleet_deploy_signal",
                "repo": repo,
                "site": site,
                "reason": reason,
                "signals_sent": signals,
                "total": len(signals),
                "status": "success",
            },
            indent=2,
        )

    @mcp.tool()
    @audit_logged(audit)
    async def fleet_deploy_status(site: str = "") -> str:
        """Query recent deploy activity across all rooms.

        Reads the agent_audit_log table for recent self_deploy and
        self_update actions within the last 24 hours.

        Args:
            site: Optional site filter. Empty = all sites.

        Returns:
            JSON with recent deploy activity per room.
        """
        db = await _get_pool()
        pool = await db.get()
        if pool is None:
            return json.dumps(
                {
                    "error": "Database unavailable",
                    "deploys": [],
                },
                indent=2,
            )

        try:
            async with pool.acquire() as conn:
                rows = await conn.fetch(
                    """SELECT project, tool, result_summary, timestamp
                       FROM agent_audit_log
                       WHERE tool IN ('self_deploy', 'self_update')
                         AND timestamp > NOW() - INTERVAL '24 hours'
                       ORDER BY timestamp DESC
                       LIMIT 50""",
                )
                deploys = []
                for row in rows:
                    result_raw = row["result_summary"] or ""
                    try:
                        result_parsed = json.loads(result_raw) if result_raw else {}
                    except (json.JSONDecodeError, TypeError):
                        result_parsed = {"raw": result_raw[:200]}

                    entry = {
                        "project": row["project"],
                        "tool": row["tool"],
                        "status": result_parsed.get("status", "unknown"),
                        "ts": row["timestamp"].isoformat(),
                    }

                    if site and site not in row["project"]:
                        continue

                    deploys.append(entry)

                return format_json(
                    {
                        "window": "24h",
                        "site_filter": site or "all",
                        "total": len(deploys),
                        "deploys": deploys,
                    }
                )
        except Exception as e:
            return json.dumps(
                {
                    "error": str(e),
                    "deploys": [],
                },
                indent=2,
            )

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def fleet_maude_update(
        site: str = "",
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Signal ALL rooms to update the maude library (self_update).

        Convenience wrapper around fleet_deploy_signal for maude library
        updates. Signals every room to pull the latest maude package.

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 5 minutes (maude updates are heavyweight).

        Args:
            site: Site filter ("site-a", "site-b", ""). Default empty = all sites.
            confirm: Must be True to proceed.
            reason: Why the maude update is needed.

        Returns:
            JSON summary of update signals sent.
        """
        _, deps, _ = get_components()
        targets = repo_to_rooms(deps, MAUDE_REPO, site=site)

        if not targets:
            return json.dumps(
                {
                    "action": "fleet_maude_update",
                    "repo": MAUDE_REPO,
                    "site": site,
                    "reason": reason,
                    "error": "No rooms found",
                    "signals_sent": [],
                    "total": 0,
                    "status": "no_targets",
                },
                indent=2,
            )

        signals = await _signal_rooms(MAUDE_REPO, targets, "self_update", reason)
        asyncio.create_task(_verify_deploys(targets))

        return json.dumps(
            {
                "action": "fleet_maude_update",
                "repo": MAUDE_REPO,
                "site": site,
                "reason": reason,
                "signals_sent": signals,
                "total": len(signals),
                "status": "success",
            },
            indent=2,
        )

    # ── fleet_local_deploy ──────────────────────────────────────────
    #
    # Maude-side executor: distributes the Maude library from
    # THIS Maude's /app/maude/src/maude/ to all local rooms
    # via same-subnet SSH. No cross-site hops.

    MAUDE_SRC = "/app/maude/src/maude/"
    FLEET_ACL = "/app/maude/fleet-acl.yaml"
    SSH_CMD = "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

    async def _deploy_to_room(
        executor: LocalExecutor,
        room: str,
        ip: str,
        project: str,
        skip_restart: bool,
    ) -> dict[str, Any]:
        """Deploy maude library to a single local room via SSH."""
        start = time.monotonic()
        steps: list[str] = []

        try:
            # 1. Connectivity check
            ping = await executor.run(f"{SSH_CMD} root@{ip} echo ok")
            if not ping.ok:
                return {
                    "room": room,
                    "ip": ip,
                    "status": "unreachable",
                    "detail": ping.stderr[:200],
                    "duration_ms": int((time.monotonic() - start) * 1000),
                }

            # 2. Backup
            ts = time.strftime("%Y%m%d-%H%M%S")
            backup_dst = f"/app/maude/src/.maude-backup-{ts}/"
            backup_cmd = f"{SSH_CMD} root@{ip} 'cp -a {MAUDE_SRC} {backup_dst}'"
            backup = await executor.run(backup_cmd)
            steps.append("backup" if backup.ok else "backup_failed")

            # 3. rsync library
            rsync_cmd = (
                f"rsync -a --delete "
                f"--exclude='__pycache__' --exclude='*.pyc' "
                f"{MAUDE_SRC} root@{ip}:{MAUDE_SRC}"
            )
            sync = await executor.run(rsync_cmd)
            if not sync.ok:
                return {
                    "room": room,
                    "ip": ip,
                    "status": "sync_failed",
                    "detail": sync.stderr[:200],
                    "steps": steps,
                    "duration_ms": int((time.monotonic() - start) * 1000),
                }
            steps.append("synced")

            # 4. Push fleet ACL
            acl_cmd = f"rsync -a {FLEET_ACL} root@{ip}:{FLEET_ACL}"
            acl = await executor.run(acl_cmd)
            steps.append("acl" if acl.ok else "acl_skipped")

            # 5. Restart
            if not skip_restart:
                restart_cmd = f"{SSH_CMD} root@{ip} 'systemctl restart maude@{project}'"
                restart = await executor.run(restart_cmd)
                if not restart.ok:
                    steps.append("restart_failed")
                    return {
                        "room": room,
                        "ip": ip,
                        "status": "restart_failed",
                        "detail": restart.stderr[:200],
                        "steps": steps,
                        "duration_ms": int((time.monotonic() - start) * 1000),
                    }
                steps.append("restarted")

                # 6. Verify (wait for service to start)
                await asyncio.sleep(5)
                verify_cmd = f"{SSH_CMD} root@{ip} 'systemctl is-active maude@{project}'"
                verify = await executor.run(verify_cmd)
                active = verify.stdout.strip() == "active"
                steps.append("active" if active else "not_active")

                if not active:
                    return {
                        "room": room,
                        "ip": ip,
                        "status": "verify_failed",
                        "detail": f"Service is '{verify.stdout.strip()}' after restart",
                        "steps": steps,
                        "duration_ms": int((time.monotonic() - start) * 1000),
                    }
            else:
                steps.append("restart_skipped")

            return {
                "room": room,
                "ip": ip,
                "status": "ok",
                "steps": steps,
                "duration_ms": int((time.monotonic() - start) * 1000),
            }

        except Exception as e:
            return {
                "room": room,
                "ip": ip,
                "status": "error",
                "detail": str(e)[:200],
                "steps": steps,
                "duration_ms": int((time.monotonic() - start) * 1000),
            }

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def fleet_local_deploy(
        rooms: str = "all",
        skip_restart: bool = False,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Deploy maude library from this Maude to all local rooms.

        Distributes the Maude library from this Maude's own
        /app/maude/src/maude/ to each room in the local site via
        same-subnet SSH. No cross-site hops — only local rooms.

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 5 minutes.

        Args:
            rooms: Comma-separated room names, or "all" for every local room.
            skip_restart: If true, sync code but don't restart services.
            confirm: Must be True to proceed.
            reason: Why the deploy is happening.

        Returns:
            JSON with per-room deploy results.
        """
        _, deps, _ = get_components()
        executor = LocalExecutor()

        # Discover local rooms (same site as this Maude)
        # Maude's own site is detected from its config IP
        all_targets = repo_to_rooms(deps, MAUDE_REPO)

        # Determine this Maude's site from its IP in the config
        import socket

        my_ip = ""
        try:
            my_ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            pass

        my_site = ""
        if my_ip.startswith("10.0."):
            my_site = "site-a"
        elif my_ip.startswith("10.0."):
            my_site = "site-b"
        elif my_ip.startswith("10.0."):
            my_site = "site-c"
        elif my_ip.startswith("10.0."):
            my_site = "site-d"

        # Filter to local site only
        if my_site:
            local_targets = [t for t in all_targets if t.get("site") == my_site]
        else:
            # Fallback: deploy to all (shouldn't happen in production)
            local_targets = all_targets
            logger.warning("Could not detect local site — deploying to all rooms")

        # Filter by room names if specified
        if rooms != "all":
            room_names = {r.strip() for r in rooms.split(",") if r.strip()}
            local_targets = [t for t in local_targets if t["room"] in room_names]

        # Exclude self (the Maude)
        local_targets = [t for t in local_targets if t.get("ip") != my_ip]

        if not local_targets:
            return format_json(
                {
                    "action": "fleet_local_deploy",
                    "site": my_site,
                    "reason": reason,
                    "error": "No local rooms found to deploy to",
                    "results": [],
                    "total": 0,
                }
            )

        # Deploy to each room (sequential to avoid SSH connection storms)
        results: list[dict[str, Any]] = []
        for target in local_targets:
            room_name = target["room"]
            ip = target.get("ip", "")
            project = target.get("room", "")  # project name = room name in most cases

            if not ip:
                results.append(
                    {
                        "room": room_name,
                        "status": "skipped",
                        "detail": "No IP in dependency graph",
                    }
                )
                continue

            result = await _deploy_to_room(executor, room_name, ip, project, skip_restart)
            results.append(result)

        success = sum(1 for r in results if r["status"] == "ok")
        failed = sum(1 for r in results if r["status"] not in ("ok", "skipped"))

        return format_json(
            {
                "action": "fleet_local_deploy",
                "site": my_site,
                "reason": reason,
                "total": len(results),
                "success": success,
                "failed": failed,
                "skipped": len(results) - success - failed,
                "results": results,
            }
        )
