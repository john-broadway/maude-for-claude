# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Sovereign site provisioning for Maude Coordinators.

Provisions rooms locally — no cross-site VPN hops. Each site's
Maude provisions its own rooms via local PVE API and local SSH.

         Claude (Anthropic) <noreply@anthropic.com>

Usage:
    from maude.coordination.site_provision import register_site_provision_tools
    register_site_provision_tools(mcp, audit, kill_switch, config)
"""

import asyncio
import json
import logging
from typing import Any

import httpx

from maude.coordination.dependencies import DependencyGraph
from maude.daemon.config import RoomConfig
from maude.daemon.guards import audit_logged, rate_limited, requires_confirm
from maude.daemon.kill_switch import KillSwitch
from maude.memory.audit import AuditLogger

logger = logging.getLogger(__name__)

# Rooms that map to Gitea repo paths (project field in dependencies.yaml)
# Maude lib is always rsynced from Maude's own /app/maude/src/maude/
GITEA_HOST = "localhost"
GITEA_SSH_PORT = 3000
GITEA_ORG = "Maude"

# LXC defaults for provisioned rooms
LXC_CORES = 2
LXC_MEMORY = 2048
LXC_ROOTFS = 16
LXC_TEMPLATE_FILENAME = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
LXC_TEMPLATE_STORAGE = "local"
# Full PVE ostemplate path: storage:vztmpl/filename
LXC_OSTEMPLATE = f"{LXC_TEMPLATE_STORAGE}:vztmpl/{LXC_TEMPLATE_FILENAME}"

# Bootstrap SSH timeout/retries
SSH_POLL_INTERVAL = 5
SSH_POLL_MAX = 12  # 60s total
SERVICE_SETTLE_SECS = 15


def _detect_site(config: RoomConfig) -> str:
    """Detect site from config IP address."""
    ip = config.ip
    if ip.startswith("203.0.113."):
        return "site-c"
    if ip.startswith("198.51.100."):
        return "site-b"
    if ip.startswith("192.0.2."):
        return "site-a"
    return ""


def _gateway_for_site(site: str) -> str:
    """Return default gateway for a site."""
    gateways = {
        "site-a": "localhost",
        "site-b": "localhost",
        "sbm": "localhost",
    }
    return gateways.get(site, "localhost")


def _pve_node_for_site(site: str) -> str:
    """Return PVE node name for a site."""
    nodes = {
        "site-a": "pve-node",
        "site-b": "pve-node",
        "sbm": "pve-node",
    }
    return nodes.get(site, "pve-node")


def _repo_path_from_project(project: str) -> str:
    """Convert project path to Gitea repo name.

    'infrastructure/postgresql' -> 'postgresql'
    'apps/example-monorepo/collector' -> 'example-monorepo'  (monorepo)
    'industrial/lab-service' -> 'lab-service'
    'industrial/alert-display' -> 'alert-display'
    'maude' -> 'maude'
    """
    parts = project.split("/")
    if len(parts) >= 2:
        # For monorepos like apps/example-monorepo/collector, the Gitea repo is 'example-monorepo'
        # For simple ones like infrastructure/postgresql, the repo is 'postgresql'
        return parts[1]
    return project


def _app_dir_from_project(project: str) -> str:
    """Determine the /app/<dir> path for a project.

    Most rooms: /app/{project}  (e.g., /app/infrastructure/postgresql)
    But the working dir is the last segment for pip install.
    """
    return f"/app/{project}"


async def _run_ssh(ip: str, cmd: str, timeout: float = 30.0) -> tuple[int, str, str]:
    """Run a command via SSH on a remote LXC.

    Uses the maude user's SSH key. Returns (returncode, stdout, stderr).
    """
    proc = await asyncio.create_subprocess_exec(
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "BatchMode=yes",
        f"root@{ip}",
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return -1, "", "SSH command timed out"
    return proc.returncode or 0, stdout.decode().strip(), stderr.decode().strip()


async def _wait_for_ssh(ip: str) -> bool:
    """Poll SSH until reachable or timeout."""
    for attempt in range(SSH_POLL_MAX):
        rc, _, _ = await _run_ssh(ip, "echo ok", timeout=10.0)
        if rc == 0:
            logger.info("SSH ready on %s after %d attempts", ip, attempt + 1)
            return True
        await asyncio.sleep(SSH_POLL_INTERVAL)
    return False


async def _call_proxmox_mcp(port: int, tool: str, args: dict[str, Any]) -> dict[str, Any]:
    """Call a tool on the co-located Proxmox MCP server via HTTP.

    FastMCP streamable-http requires a full handshake:
    initialize → notifications/initialized → tools/call
    """
    url = f"http://localhost:{port}/mcp"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        # Step 1: Initialize
        init_resp = await client.post(
            url,
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "site-provision", "version": "1.0"},
                },
            },
        )
        init_resp.raise_for_status()
        session_id = init_resp.headers.get("mcp-session-id", "")

        session_headers = {**headers, "Mcp-Session-Id": session_id}

        # Step 2: Send initialized notification
        await client.post(
            url,
            headers=session_headers,
            json={
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            },
        )

        # Step 3: Call the tool
        resp = await client.post(
            url,
            headers=session_headers,
            json={
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": tool, "arguments": args},
            },
        )
        resp.raise_for_status()
        data = resp.json()

    # MCP response: result.content[0].text (JSON string)
    result = data.get("result", {})
    content = result.get("content", [])
    if content and isinstance(content, list):
        text = content[0].get("text", "{}")
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"raw": text}
    return result


def register_site_provision_tools(
    mcp: Any,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    config: RoomConfig,
) -> None:
    """Register sovereign site provisioning tools on the Coordinator.

    Args:
        mcp: FastMCP server instance.
        audit: AuditLogger for recording tool calls.
        kill_switch: KillSwitch for guarding mutating operations.
        config: RoomConfig for this Maude instance.
    """
    site = _detect_site(config)
    gateway = _gateway_for_site(site)
    proxmox_port = config.raw.get("proxmox_mcp_port", config.ctid)

    # Load SSH public key for injecting into new LXCs
    ssh_pub_key = ""
    from pathlib import Path as _Path

    for key_path in [
        "/etc/maude/ssh_provision.pub",
        "/home/maude/.ssh/id_ed25519.pub",
    ]:
        try:
            ssh_pub_key = _Path(key_path).read_text().strip()
            break
        except (FileNotFoundError, PermissionError):
            continue

    @mcp.tool()
    @audit_logged(audit)
    async def site_provision_plan(site_filter: str = "") -> str:
        """Discover rooms for this site and report provisioning status.

        Reads the dependency graph, filters rooms for the current site,
        and SSH-probes each IP to determine which exist vs which are missing.
        Returns rooms grouped by dependency tier for ordered provisioning.

        Args:
            site_filter: Override site detection. Default = auto-detect from config IP.

        Returns:
            JSON with rooms, status (running/missing), and dependency tiers.
        """
        target_site = site_filter or site
        if not target_site:
            return json.dumps({"error": "Cannot detect site from config IP"}, indent=2)

        deps = DependencyGraph()
        site_rooms = deps.rooms_by_site(target_site)

        if not site_rooms:
            return json.dumps(
                {
                    "site": target_site,
                    "error": f"No rooms found for site '{target_site}'",
                    "rooms": [],
                },
                indent=2,
            )

        # Probe each room via SSH
        results = []
        for qualified_name in site_rooms:
            meta = deps.room_info(qualified_name)
            ip = meta.get("ip", "")
            bare_name = qualified_name.split("/", 1)[-1]

            # Quick SSH probe
            rc, _, _ = await _run_ssh(ip, "echo ok", timeout=8.0)
            status = "running" if rc == 0 else "missing"

            results.append(
                {
                    "room": bare_name,
                    "qualified": qualified_name,
                    "ip": ip,
                    "ctid": meta.get("ctid", 0),
                    "project": meta.get("project", ""),
                    "layer": meta.get("layer", ""),
                    "depends_on": [d.split("/", 1)[-1] for d in meta.get("depends_on", [])],
                    "status": status,
                }
            )

        # Compute tiers from dependency graph
        room_names = {r["room"] for r in results}
        room_by_name = {r["room"]: r for r in results}

        def _compute_tier(room: dict[str, Any]) -> int:
            local_deps = [d for d in room["depends_on"] if d in room_names]
            if not local_deps:
                return 0
            all_tier0 = all(
                not [d2 for d2 in room_by_name.get(d, {}).get("depends_on", []) if d2 in room_names]
                for d in local_deps
            )
            return 1 if all_tier0 else 2

        for r in results:
            r["tier"] = _compute_tier(r)

        running = [r for r in results if r["status"] == "running"]
        missing = [r for r in results if r["status"] == "missing"]

        tiers: dict[int, list[str]] = {0: [], 1: [], 2: []}
        for r in missing:
            tiers.setdefault(r["tier"], []).append(r["room"])

        return json.dumps(
            {
                "site": target_site,
                "total_rooms": len(results),
                "running": len(running),
                "missing": len(missing),
                "rooms": results,
                "provision_order": {f"tier_{k}": sorted(v) for k, v in sorted(tiers.items())},
            },
            indent=2,
        )

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=30.0)
    async def site_provision_room(
        room_name: str,
        confirm: bool = False,
        reason: str = "",
    ) -> str:
        """Provision a single room on this site's PVE host.

        Creates the LXC container, waits for SSH, and bootstraps the
        maude environment (user, venv, source, systemd service).

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 30 seconds.

        Args:
            room_name: Bare room name (e.g., "database", "my-service").
            confirm: Must be True to proceed.
            reason: Why this room is being provisioned.

        Returns:
            JSON with provisioning result.
        """
        target_site = site
        if not target_site:
            return json.dumps({"error": "Cannot detect site"}, indent=2)

        deps = DependencyGraph()
        qualified = f"{target_site}/{room_name}"
        meta = deps.room_info(qualified)

        if not meta.get("ip"):
            return json.dumps(
                {
                    "error": f"Room '{room_name}' not found in site '{target_site}'",
                    "room": room_name,
                    "site": target_site,
                },
                indent=2,
            )

        ctid = meta["ctid"]
        ip = meta["ip"]
        project = meta.get("project", "")
        mcp_port = meta.get("mcp_port", ctid)

        logger.info(
            "Provisioning %s (CTID %d, IP %s, project %s)",
            room_name,
            ctid,
            ip,
            project,
        )

        steps: list[dict[str, Any]] = []

        # Step 1: Check if already running
        rc, _, _ = await _run_ssh(ip, "echo ok", timeout=8.0)
        if rc == 0:
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "already_running",
                    "message": f"Room {room_name} at {ip} is already reachable via SSH",
                },
                indent=2,
            )

        # Step 2: Download LXC template if needed
        try:
            dl_result = await _call_proxmox_mcp(
                proxmox_port,
                "pve_download_template",
                {
                    "site": target_site,
                    "storage": LXC_TEMPLATE_STORAGE,
                    "template": LXC_TEMPLATE_FILENAME,
                    "confirm": True,
                    "reason": reason,
                },
            )
            steps.append(
                {
                    "step": "download_template",
                    "status": "ok",
                    "detail": str(dl_result.get("status", "done")),
                }
            )
        except Exception as e:
            # Template may already be cached — continue
            steps.append(
                {
                    "step": "download_template",
                    "status": "skipped",
                    "detail": str(e)[:200],
                }
            )

        # Step 3: Create LXC container
        hostname = room_name
        net_config = f"name=eth0,bridge=vmbr0,ip={ip}/24,gw={gateway}"

        try:
            create_result = await _call_proxmox_mcp(
                proxmox_port,
                "pve_create_lxc",
                {
                    "site": target_site,
                    "vmid": ctid,
                    "hostname": hostname,
                    "ostemplate": LXC_OSTEMPLATE,
                    "cores": LXC_CORES,
                    "memory": LXC_MEMORY,
                    "rootfs_size": LXC_ROOTFS,
                    "net": net_config,
                    "ssh_public_keys": ssh_pub_key,
                    "start": True,
                    "confirm": True,
                    "reason": reason,
                },
            )
            steps.append(
                {
                    "step": "create_lxc",
                    "status": "ok",
                    "detail": create_result,
                }
            )
        except Exception as e:
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "failed",
                    "failed_step": "create_lxc",
                    "error": str(e)[:500],
                    "steps": steps,
                },
                indent=2,
            )

        # Step 4: Wait for SSH
        ssh_ok = await _wait_for_ssh(ip)
        if not ssh_ok:
            steps.append({"step": "wait_ssh", "status": "timeout"})
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "failed",
                    "failed_step": "wait_ssh",
                    "error": f"SSH not reachable at {ip} after {SSH_POLL_MAX * SSH_POLL_INTERVAL}s",
                    "steps": steps,
                },
                indent=2,
            )
        steps.append({"step": "wait_ssh", "status": "ok"})

        # Step 5: Bootstrap interior
        app_dir = _app_dir_from_project(project)
        repo_name = _repo_path_from_project(project)
        service_instance = project.split("/")[-1]

        bootstrap_commands = [
            # Create maude system user
            "id -u maude >/dev/null 2>&1 || "
            "useradd -r -s /usr/sbin/nologin -d /home/maude -m maude",
            "usermod -aG systemd-journal maude",
            # Create directory structure
            f"mkdir -p {app_dir}",
            "mkdir -p /app/maude/src",
            "mkdir -p /etc/maude",
            f"mkdir -p /var/lib/maude/{service_instance}",
            # Install Python + venv + git
            (
                "apt-get update -qq"
                " && apt-get install -y -qq python3 python3-venv python3-pip git openssh-client"
                " > /dev/null 2>&1"
            ),
        ]

        for cmd in bootstrap_commands:
            rc, _, stderr = await _run_ssh(ip, cmd, timeout=120.0)
            if rc != 0:
                steps.append(
                    {
                        "step": "bootstrap_setup",
                        "status": "failed",
                        "cmd": cmd[:100],
                        "stderr": stderr[:300],
                    }
                )
                return json.dumps(
                    {
                        "room": room_name,
                        "ctid": ctid,
                        "ip": ip,
                        "status": "failed",
                        "failed_step": "bootstrap_setup",
                        "error": stderr[:500],
                        "steps": steps,
                    },
                    indent=2,
                )

        steps.append({"step": "bootstrap_setup", "status": "ok"})

        # Step 6: Copy secrets from Maude
        scp_proc = await asyncio.create_subprocess_exec(
            "scp",
            "-o",
            "StrictHostKeyChecking=no",
            "/etc/maude/secrets.yaml",
            f"root@{ip}:/etc/maude/secrets.yaml",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await scp_proc.communicate()
        await _run_ssh(
            ip,
            "chown root:maude /etc/maude/secrets.yaml && chmod 0640 /etc/maude/secrets.yaml",
        )
        steps.append({"step": "copy_secrets", "status": "ok"})

        # Step 7: Deploy polkit rules for service restart
        polkit_rule = (
            "polkit.addRule(function(action, subject) {\n"
            '  if (action.id == "org.freedesktop.systemd1.manage-units" &&\n'
            '      action.lookup("unit").indexOf("maude@") === 0 &&\n'
            '      subject.user == "maude") {\n'
            "    return polkit.Result.YES;\n"
            "  }\n"
            "});\n"
        )
        await _run_ssh(
            ip,
            "mkdir -p /etc/polkit-1/rules.d"
            " && cat > /etc/polkit-1/rules.d/49-maude.rules << 'POLKIT'\n"
            f"{polkit_rule}POLKIT",
        )
        steps.append({"step": "polkit_rules", "status": "ok"})

        # Step 8: Create venv
        rc, _, stderr = await _run_ssh(
            ip,
            f"python3 -m venv {app_dir}/.venv",
            timeout=60.0,
        )
        if rc != 0:
            steps.append(
                {
                    "step": "create_venv",
                    "status": "failed",
                    "stderr": stderr[:200],
                }
            )
        else:
            steps.append({"step": "create_venv", "status": "ok"})

        # Step 9: Rsync Maude lib from Maude's local copy
        rsync_proc = await asyncio.create_subprocess_exec(
            "rsync",
            "-az",
            "--delete",
            "/app/maude/src/maude/",
            f"root@{ip}:/app/maude/src/maude/",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await asyncio.wait_for(rsync_proc.communicate(), timeout=60.0)
        steps.append({"step": "rsync_maude_lib", "status": "ok"})

        # Also rsync pyproject.toml for pip install -e
        rsync_proc2 = await asyncio.create_subprocess_exec(
            "rsync",
            "-az",
            "/app/maude/pyproject.toml",
            f"root@{ip}:/app/maude/pyproject.toml",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await asyncio.wait_for(rsync_proc2.communicate(), timeout=30.0)

        # Step 10: Clone project source from Gitea-SLC
        git_url = f"ssh://git@{GITEA_HOST}:{GITEA_SSH_PORT}/{GITEA_ORG}/{repo_name}.git"
        rc, _, stderr = await _run_ssh(
            ip,
            f"if [ ! -d {app_dir}/.git ]; then "
            f"GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' "
            f"git clone {git_url} {app_dir}; fi",
            timeout=120.0,
        )
        if rc != 0:
            steps.append(
                {
                    "step": "git_clone",
                    "status": "warning",
                    "stderr": stderr[:200],
                }
            )
        else:
            steps.append({"step": "git_clone", "status": "ok"})

        # Step 11: pip install maude + project
        pip_cmd = f"{app_dir}/.venv/bin/pip install --quiet -e '/app/maude[cache]' -e '{app_dir}'"
        rc, _, stderr = await _run_ssh(ip, pip_cmd, timeout=300.0)
        if rc != 0:
            steps.append(
                {
                    "step": "pip_install",
                    "status": "warning",
                    "stderr": stderr[:300],
                }
            )
        else:
            steps.append({"step": "pip_install", "status": "ok"})

        # Step 12: Write config-local.yaml
        config_yaml = (
            f"project: {project}\n"
            f"service_name: {service_instance}\n"
            f"ctid: {ctid}\n"
            f'ip: "{ip}"\n'
            f"mcp_port: {mcp_port}\n"
            f"executor_mode: local\n"
        )
        await _run_ssh(
            ip,
            f"cat > {app_dir}/config-local.yaml << 'YAML'\n{config_yaml}YAML",
        )
        steps.append({"step": "write_config", "status": "ok"})

        # Step 13: Write maude.env
        module_map = {
            "infrastructure/postgresql": "maude.rooms.postgresql",
            "infrastructure/redis": "maude.rooms.redis",
            "infrastructure/prometheus": "maude.rooms.prometheus",
            "infrastructure/loki": "maude.rooms.loki",
            "infrastructure/grafana": "maude.rooms.grafana",
            "infrastructure/uptime-kuma": "maude.rooms.uptime_kuma",
            "infrastructure/gitea": "maude.rooms.gitea",
            "infrastructure/dns": "maude.rooms.dns",
            "infrastructure/ntp": "maude.rooms.ntp",
            "infrastructure/authentik": "maude.rooms.authentik",
            "infrastructure/wazuh": "maude.rooms.wazuh",
            "infrastructure/fleet": "maude.rooms.fleet",
            "infrastructure/mint": "mint.mcp",
            "apps/example-monorepo/collector": "collector.mcp",
            "industrial/example-scada/panel": "panel.mcp",
            "industrial/lab-service": "lab_service.mcp",
            "industrial/alert-display": "alert_display.mcp",
        }
        maude_module = module_map.get(project, f"{service_instance}.mcp")
        maude_env = f"MAUDE_MODULE={maude_module}\nMAUDE_PORT={mcp_port}\n"
        await _run_ssh(
            ip,
            f"cat > {app_dir}/maude.env << 'ENV'\n{maude_env}ENV",
        )
        steps.append({"step": "write_env", "status": "ok"})

        # Step 14: Deploy systemd template + enable + start
        systemd_unit = (
            "[Unit]\n"
            "Description=Maude Room Agent (%i)\n"
            "After=network-online.target\n"
            "Wants=network-online.target\n"
            "\n"
            "[Service]\n"
            "Type=simple\n"
            "User=maude\n"
            "Group=maude\n"
            "WorkingDirectory=/app/%i\n"
            "EnvironmentFile=/app/%i/maude.env\n"
            "ExecStart=/app/%i/.venv/bin/python -m ${MAUDE_MODULE}"
            " --port ${MAUDE_PORT}\n"
            "Restart=on-failure\n"
            "RestartSec=5\n"
            "NoNewPrivileges=true\n"
            "ProtectSystem=strict\n"
            "PrivateTmp=true\n"
            "PrivateDevices=true\n"
            f"ReadWritePaths=/var/lib/maude/{service_instance} /app/%i\n"
            "SyslogIdentifier=maude@%i\n"
            "\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n"
        )
        await _run_ssh(
            ip,
            f"cat > /etc/systemd/system/maude@.service << 'UNIT'\n{systemd_unit}UNIT",
        )

        # Fix ownership
        await _run_ssh(
            ip,
            f"chown -R maude:maude {app_dir} /app/maude /var/lib/maude/{service_instance}",
        )

        # Enable and start
        await _run_ssh(ip, "systemctl daemon-reload")
        rc, _, stderr = await _run_ssh(
            ip,
            f"systemctl enable maude@{service_instance}"
            f" && systemctl start maude@{service_instance}",
            timeout=30.0,
        )
        if rc != 0:
            steps.append(
                {
                    "step": "systemd_start",
                    "status": "failed",
                    "stderr": stderr[:200],
                }
            )
        else:
            steps.append({"step": "systemd_start", "status": "ok"})

        # Step 15: Wait and verify
        await asyncio.sleep(SERVICE_SETTLE_SECS)
        rc, stdout, _ = await _run_ssh(
            ip,
            f"systemctl is-active maude@{service_instance}",
        )
        service_active = stdout.strip() == "active"
        steps.append(
            {
                "step": "verify_active",
                "status": "ok" if service_active else "failed",
                "service_state": stdout.strip(),
            }
        )

        return json.dumps(
            {
                "room": room_name,
                "ctid": ctid,
                "ip": ip,
                "project": project,
                "mcp_port": mcp_port,
                "status": "provisioned" if service_active else "partial",
                "service_active": service_active,
                "steps": steps,
            },
            indent=2,
        )

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    @rate_limited(min_interval_seconds=300.0)
    async def site_provision_batch(
        confirm: bool = False,
        reason: str = "",
        dry_run: bool = False,
    ) -> str:
        """Provision all missing rooms for this site in dependency order.

        Discovers missing rooms via SSH probe, computes dependency tiers,
        and provisions each room sequentially within each tier.

        Skips rooms that are already running (SSH reachable).

        GUARDED: requires confirm=True and reason. Rate-limited to once
        per 5 minutes.

        Args:
            confirm: Must be True to proceed.
            reason: Why the batch provision is happening.
            dry_run: If True, only report what would be provisioned.

        Returns:
            JSON summary of all provisioning results.
        """
        target_site = site
        if not target_site:
            return json.dumps({"error": "Cannot detect site"}, indent=2)

        deps = DependencyGraph()
        site_rooms = deps.rooms_by_site(target_site)

        # Probe all rooms
        room_status: dict[str, dict[str, Any]] = {}
        for qualified_name in site_rooms:
            meta = deps.room_info(qualified_name)
            ip = meta.get("ip", "")
            bare_name = qualified_name.split("/", 1)[-1]

            rc, _, _ = await _run_ssh(ip, "echo ok", timeout=8.0)
            room_status[bare_name] = {
                "qualified": qualified_name,
                "ip": ip,
                "ctid": meta.get("ctid", 0),
                "project": meta.get("project", ""),
                "layer": meta.get("layer", ""),
                "depends_on": [d.split("/", 1)[-1] for d in meta.get("depends_on", [])],
                "running": rc == 0,
            }

        missing = {name: info for name, info in room_status.items() if not info["running"]}

        if not missing:
            return json.dumps(
                {
                    "site": target_site,
                    "status": "all_running",
                    "total_rooms": len(room_status),
                    "running": len(room_status),
                    "missing": 0,
                    "message": "All rooms are already running",
                },
                indent=2,
            )

        # Compute tiers
        all_room_names = set(room_status.keys())

        def _tier(name: str) -> int:
            info = room_status.get(name, {})
            local_deps = [d for d in info.get("depends_on", []) if d in all_room_names]
            if not local_deps:
                return 0
            for dep in local_deps:
                dep_info = room_status.get(dep, {})
                dep_local = [d for d in dep_info.get("depends_on", []) if d in all_room_names]
                if dep_local:
                    return 2
            return 1

        tiers: dict[int, list[str]] = {0: [], 1: [], 2: []}
        for name in missing:
            tier = _tier(name)
            tiers.setdefault(tier, []).append(name)

        for t in tiers:
            tiers[t].sort()

        if dry_run:
            return json.dumps(
                {
                    "site": target_site,
                    "dry_run": True,
                    "total_rooms": len(room_status),
                    "running": len(room_status) - len(missing),
                    "to_provision": len(missing),
                    "provision_order": {f"tier_{k}": v for k, v in sorted(tiers.items()) if v},
                    "rooms": {
                        name: {
                            "ctid": info["ctid"],
                            "ip": info["ip"],
                            "project": info["project"],
                            "tier": _tier(name),
                        }
                        for name, info in missing.items()
                    },
                },
                indent=2,
            )

        # Provision in tier order
        results: list[dict[str, Any]] = []
        for tier_num in sorted(tiers.keys()):
            tier_rooms = tiers[tier_num]
            if not tier_rooms:
                continue

            logger.info("Provisioning tier %d: %s", tier_num, tier_rooms)

            for name in tier_rooms:
                logger.info("Provisioning %s (tier %d)", name, tier_num)
                try:
                    result_json = await _provision_one_room(
                        name,
                        target_site,
                        deps,
                        proxmox_port,
                        gateway,
                        reason=f"Batch: {reason} (tier {tier_num})",
                    )
                    result = json.loads(result_json)
                    result["tier"] = tier_num
                    results.append(result)
                except Exception as e:
                    results.append(
                        {
                            "room": name,
                            "tier": tier_num,
                            "status": "error",
                            "error": str(e)[:500],
                        }
                    )

        succeeded = sum(1 for r in results if r.get("status") == "provisioned")
        failed = sum(
            1 for r in results if r.get("status") not in ("provisioned", "already_running")
        )

        return json.dumps(
            {
                "site": target_site,
                "reason": reason,
                "total_rooms": len(room_status),
                "already_running": len(room_status) - len(missing),
                "provisioned": succeeded,
                "failed": failed,
                "results": results,
                "status": "complete" if failed == 0 else "partial",
            },
            indent=2,
        )

    # Internal helper for batch — avoids calling through guard decorators
    async def _provision_one_room(
        room_name: str,
        target_site: str,
        deps: DependencyGraph,
        pve_port: int,
        gw: str,
        reason: str = "",
    ) -> str:
        """Provision a single room (no guards — called from batch)."""
        qualified = f"{target_site}/{room_name}"
        meta = deps.room_info(qualified)

        if not meta.get("ip"):
            return json.dumps(
                {
                    "error": f"Room '{room_name}' not found",
                    "room": room_name,
                },
                indent=2,
            )

        ctid = meta["ctid"]
        ip = meta["ip"]
        project = meta.get("project", "")
        mcp_port_val = meta.get("mcp_port", ctid)
        app_dir = _app_dir_from_project(project)
        repo_name = _repo_path_from_project(project)
        service_instance = project.split("/")[-1]

        steps: list[dict[str, Any]] = []

        # Check if already running
        rc, _, _ = await _run_ssh(ip, "echo ok", timeout=8.0)
        if rc == 0:
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "already_running",
                },
                indent=2,
            )

        # Download template
        try:
            await _call_proxmox_mcp(
                pve_port,
                "pve_download_template",
                {
                    "site": target_site,
                    "storage": LXC_TEMPLATE_STORAGE,
                    "template": LXC_TEMPLATE_FILENAME,
                    "confirm": True,
                    "reason": reason,
                },
            )
            steps.append({"step": "download_template", "status": "ok"})
        except Exception:
            steps.append({"step": "download_template", "status": "skipped"})

        # Create LXC
        net_config = f"name=eth0,bridge=vmbr0,ip={ip}/24,gw={gw}"
        try:
            await _call_proxmox_mcp(
                pve_port,
                "pve_create_lxc",
                {
                    "site": target_site,
                    "vmid": ctid,
                    "hostname": room_name,
                    "ostemplate": LXC_OSTEMPLATE,
                    "cores": LXC_CORES,
                    "memory": LXC_MEMORY,
                    "rootfs_size": LXC_ROOTFS,
                    "net": net_config,
                    "ssh_public_keys": ssh_pub_key,
                    "start": True,
                    "confirm": True,
                    "reason": reason,
                },
            )
            steps.append({"step": "create_lxc", "status": "ok"})
        except Exception as e:
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "failed",
                    "failed_step": "create_lxc",
                    "error": str(e)[:500],
                    "steps": steps,
                },
                indent=2,
            )

        # Wait for SSH
        if not await _wait_for_ssh(ip):
            return json.dumps(
                {
                    "room": room_name,
                    "ctid": ctid,
                    "ip": ip,
                    "status": "failed",
                    "failed_step": "wait_ssh",
                    "steps": steps,
                },
                indent=2,
            )
        steps.append({"step": "wait_ssh", "status": "ok"})

        # Bootstrap
        for cmd in [
            "id -u maude >/dev/null 2>&1 || "
            "useradd -r -s /usr/sbin/nologin -d /home/maude -m maude",
            "usermod -aG systemd-journal maude",
            (f"mkdir -p {app_dir} /app/maude/src /etc/maude /var/lib/maude/{service_instance}"),
            (
                "apt-get update -qq"
                " && apt-get install -y -qq python3 python3-venv python3-pip git openssh-client"
                " > /dev/null 2>&1"
            ),
        ]:
            rc, _, stderr = await _run_ssh(ip, cmd, timeout=120.0)
            if rc != 0:
                return json.dumps(
                    {
                        "room": room_name,
                        "ctid": ctid,
                        "ip": ip,
                        "status": "failed",
                        "failed_step": "bootstrap",
                        "error": stderr[:500],
                        "steps": steps,
                    },
                    indent=2,
                )
        steps.append({"step": "bootstrap", "status": "ok"})

        # Copy secrets
        scp_proc = await asyncio.create_subprocess_exec(
            "scp",
            "-o",
            "StrictHostKeyChecking=no",
            "/etc/maude/secrets.yaml",
            f"root@{ip}:/etc/maude/secrets.yaml",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await scp_proc.communicate()
        await _run_ssh(
            ip,
            "chown root:maude /etc/maude/secrets.yaml && chmod 0640 /etc/maude/secrets.yaml",
        )

        # Polkit
        polkit_rule = (
            "polkit.addRule(function(action, subject) {\n"
            '  if (action.id == "org.freedesktop.systemd1.manage-units" &&\n'
            '      action.lookup("unit").indexOf("maude@") === 0 &&\n'
            '      subject.user == "maude") {\n'
            "    return polkit.Result.YES;\n"
            "  }\n"
            "});\n"
        )
        await _run_ssh(
            ip,
            "mkdir -p /etc/polkit-1/rules.d"
            " && cat > /etc/polkit-1/rules.d/49-maude.rules << 'POLKIT'\n"
            f"{polkit_rule}POLKIT",
        )

        # Venv + rsync maude + pyproject
        await _run_ssh(ip, f"python3 -m venv {app_dir}/.venv", timeout=60.0)

        for src, dst in [
            ("/app/maude/src/maude/", f"root@{ip}:/app/maude/src/maude/"),
            ("/app/maude/pyproject.toml", f"root@{ip}:/app/maude/pyproject.toml"),
        ]:
            p = await asyncio.create_subprocess_exec(
                "rsync",
                "-az",
                *(["--delete"] if src.endswith("/") else []),
                src,
                dst,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(p.communicate(), timeout=60.0)

        # Git clone
        git_url = f"ssh://git@{GITEA_HOST}:{GITEA_SSH_PORT}/{GITEA_ORG}/{repo_name}.git"
        await _run_ssh(
            ip,
            f"if [ ! -d {app_dir}/.git ]; then "
            f"GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' "
            f"git clone {git_url} {app_dir}; fi",
            timeout=120.0,
        )

        # pip install
        await _run_ssh(
            ip,
            f"{app_dir}/.venv/bin/pip install --quiet -e '/app/maude[cache]' -e '{app_dir}'",
            timeout=300.0,
        )

        # config-local.yaml
        config_yaml = (
            f"project: {project}\n"
            f"service_name: {service_instance}\n"
            f"ctid: {ctid}\n"
            f'ip: "{ip}"\n'
            f"mcp_port: {mcp_port_val}\n"
            f"executor_mode: local\n"
        )
        await _run_ssh(
            ip,
            f"cat > {app_dir}/config-local.yaml << 'YAML'\n{config_yaml}YAML",
        )

        # maude.env
        module_map = {
            "infrastructure/postgresql": "maude.rooms.postgresql",
            "infrastructure/redis": "maude.rooms.redis",
            "infrastructure/prometheus": "maude.rooms.prometheus",
            "infrastructure/loki": "maude.rooms.loki",
            "infrastructure/grafana": "maude.rooms.grafana",
            "infrastructure/uptime-kuma": "maude.rooms.uptime_kuma",
            "infrastructure/gitea": "maude.rooms.gitea",
            "infrastructure/dns": "maude.rooms.dns",
            "infrastructure/ntp": "maude.rooms.ntp",
            "infrastructure/authentik": "maude.rooms.authentik",
            "infrastructure/wazuh": "maude.rooms.wazuh",
            "infrastructure/fleet": "maude.rooms.fleet",
            "infrastructure/mint": "mint.mcp",
            "apps/example-monorepo/collector": "collector.mcp",
            "industrial/example-scada/panel": "panel.mcp",
            "industrial/lab-service": "lab_service.mcp",
            "industrial/alert-display": "alert_display.mcp",
        }
        maude_module = module_map.get(project, f"{service_instance}.mcp")
        await _run_ssh(
            ip,
            f"cat > {app_dir}/maude.env << 'ENV'\n"
            f"MAUDE_MODULE={maude_module}\n"
            f"MAUDE_PORT={mcp_port_val}\n"
            "ENV",
        )

        # Systemd
        systemd_unit = (
            "[Unit]\n"
            "Description=Maude Room Agent (%i)\n"
            "After=network-online.target\n"
            "Wants=network-online.target\n"
            "\n"
            "[Service]\n"
            "Type=simple\n"
            "User=maude\n"
            "Group=maude\n"
            "WorkingDirectory=/app/%i\n"
            "EnvironmentFile=/app/%i/maude.env\n"
            "ExecStart=/app/%i/.venv/bin/python -m ${MAUDE_MODULE}"
            " --port ${MAUDE_PORT}\n"
            "Restart=on-failure\n"
            "RestartSec=5\n"
            "NoNewPrivileges=true\n"
            "ProtectSystem=strict\n"
            "PrivateTmp=true\n"
            "PrivateDevices=true\n"
            f"ReadWritePaths=/var/lib/maude/{service_instance} /app/%i\n"
            "SyslogIdentifier=maude@%i\n"
            "\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n"
        )
        await _run_ssh(
            ip,
            f"cat > /etc/systemd/system/maude@.service << 'UNIT'\n{systemd_unit}UNIT",
        )

        # Ownership + start
        await _run_ssh(
            ip,
            f"chown -R maude:maude {app_dir} /app/maude /var/lib/maude/{service_instance}",
        )
        await _run_ssh(ip, "systemctl daemon-reload")
        await _run_ssh(
            ip,
            f"systemctl enable maude@{service_instance}"
            f" && systemctl start maude@{service_instance}",
            timeout=30.0,
        )

        # Verify
        await asyncio.sleep(SERVICE_SETTLE_SECS)
        rc, stdout, _ = await _run_ssh(
            ip,
            f"systemctl is-active maude@{service_instance}",
        )
        active = stdout.strip() == "active"

        return json.dumps(
            {
                "room": room_name,
                "ctid": ctid,
                "ip": ip,
                "project": project,
                "mcp_port": mcp_port_val,
                "status": "provisioned" if active else "partial",
                "service_active": active,
                "steps": steps,
            },
            indent=2,
        )
