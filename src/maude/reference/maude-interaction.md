# Maude Interaction — How John Talks to Rooms

> **Version:** 1.4
> **Created:** 2026-01-31
> **Last Updated:** 2026-02-04 20:34 MST
> **Status:** MANDATORY

---

## The Rule

**Every LXC is autonomous.** Each runs a Maude daemon (`maude` package) providing MCP tools, Room Agent, Health Loop, 4-tier memory, and self-healing. The control plane's role is development and deployment — not runtime operations.

Every LXC runs a Maude daemon — a Streamable HTTP MCP server at `http://<ip>:9<ctid>/mcp`. **Use these MCP tools for ALL operational queries. Never SSH for status, logs, health, or data.**

---

## Architecture

```
Control Plane                    LXC (e.g., 106)
├── ~/projects/maude/            ├── /app/collector/
│   └── src/maude/ (library)      │   ├── maude/src/ (deployed copy)
├── ~/projects/collector/          │   ├── collector/src/ (deployed copy)
│   └── src/ (development)         │   ├── knowledge/ (Tier 1 brain)
│                                  │   ├── .venv/ (runtime)
│                                  │   └── config-local.yaml
│                                  ├── collector-mcp.service (Maude daemon)
│                                  │   ├── MCP tools (14+)
│                                  │   ├── Room Agent (autonomous)
│                                  │   ├── Health Loop (self-healing)
│                                  │   └── Memory (4-tier)
│                                  └── collector.service (app)
```

- **You** = development, deployment, code changes
- **LXC** = autonomous runtime with its own agents, memory, and self-healing
- **Maude** = the daemon package (`~/projects/maude/`) deployed to every LXC
- **Skills/Agents** = how you interact with Rooms (e.g., `/collector`, `/grafana`)

---

## When SSH Is Acceptable

SSH is ONLY acceptable for:
1. **Deployment** — rsync code from John to LXC
2. **Package installation** — pip install in LXC venv
3. **Infrastructure setup** — git init, systemd unit changes, one-time config
4. **MCP server itself is down** — emergency recovery when tools are unavailable

SSH is NEVER acceptable for: health checks, log reading, status queries, database queries, metrics collection, or any operation that has an MCP tool equivalent

---

## How to Call Maude Tools

### Helper Script

```bash
~/.claude/scripts/maude-call.sh <host:port> <tool_name> [json_args]
```

**Examples:**
```bash
# PostgreSQL health
maude-call.sh localhost:9201 service_health

# Collector data freshness
maude-call.sh localhost:9206 collector_data_freshness

# Grafana dashboard list
maude-call.sh localhost:9204 grafana_dashboard_list

# Tool with arguments
maude-call.sh localhost:9201 service_logs '{"lines": 50, "filter": "error"}'
```

### Raw curl Pattern

If the helper script isn't available:

```bash
# Step 1: Initialize session
curl -sD /dev/stderr http://<ip>:<port>/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"john","version":"1.0"}}}'

# Extract Mcp-Session-Id from response headers

# Step 2: Call tool
curl -s http://<ip>:<port>/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"<tool>","arguments":{}}}'
```

### Key Protocol Details

- **Transport:** Streamable HTTP (not SSE, not stdio)
- **Endpoint:** Always `/mcp`
- **Port:** assigned per-room (e.g., CTID 130/postgresql → port 9201, CTID 150/collector → port 9206) — see Room Directory below
- **Session:** `initialize` first to get `Mcp-Session-Id`, then include on all calls
- **Accept header:** Must be `application/json, text/event-stream`
- **Response format:** SSE `event: message\ndata: {jsonrpc result}`

---

## Room Directory

| Room | CTID | IP | Port | Skill |
|------|------|----|------|-------|
| pbs | 102 | 192.0.2.2 | 9100 | `/pbs` |
| postgresql | 130 | 192.0.2.30 | 9201 | `/postgresql` |
| influxdb | 131 | 192.0.2.31 | 9202 | `/influxdb` |
| qdrant | 132 | 192.0.2.32 | 9203 | `/qdrant` |
| grafana | 140 | 192.0.2.40 | 9204 | `/grafana` |
| prometheus | 141 | 192.0.2.41 | 9205 | `/prometheus` |
| collector | 150 | 192.0.2.50 | 9206 | `/collector` |
| panel | 151 | 192.0.2.51 | 9207 | `/panel` |
| loki | 142 | 192.0.2.42 | 9208 | `/loki` |
| uptime-kuma | 143 | 192.0.2.43 | 9209 | `/uptime-kuma` |
| gitea | 160 | 192.0.2.60 | 9210 | `/gitea` |
| redis | 133 | 192.0.2.33 | 9211 | `/redis` |
| lab-service | 152 | 192.0.2.52 | 9212 | `/lab` |
| gpu-node-1 | 172* | 192.0.2.72 | 9300 | `/sparks` |
| gpu-node-2 | 173* | 192.0.2.73 | 9301 | `/sparks` |

*Standalone GPU machines, not Proxmox LXCs.

---

## Common Tools (All Rooms)

Every Maude daemon provides these base tools:

| Tool | Type | Description |
|------|------|-------------|
| `service_status` | Read | systemd state, PID, memory, uptime |
| `service_health` | Read | Composite: service + memory + disk + errors |
| `service_logs` | Read | Recent journal entries (args: lines, filter) |
| `service_errors` | Read | Error-level entries (args: lines, since) |
| `service_restart` | Write | Guarded: requires confirm + reason, 2min rate limit |
| `kill_switch_status` | Admin | Check read-only flag |
| `kill_switch_activate` | Admin | Block writes (requires confirm + reason) |
| `kill_switch_deactivate` | Admin | Allow writes (requires confirm) |
| `memory_*` | Memory | 9 tools for four-tier recall (Tier 1 .md, Tier 1.5 SQLite, Tier 2 PG, Tier 3 Qdrant) |

Plus project-specific domain tools (see `~/.claude/reference/mcp-servers.md`).

---

## Routing Priority

1. **Maude MCP tools** (via maude-call.sh or curl) — for ALL operational queries
2. **`/skill` commands** (via Skill tool) — for interactive advisory workflows
3. **Shared stdio MCPs** (`pve_*`, `unifi_*`, `plc_*`, `mcp__postgres__query`) — for cross-cutting queries
4. **SSH** — ONLY for deployment (rsync, pip install, systemd unit changes)

---

## Anti-Patterns

| Anti-Pattern | Correct Approach |
|--------------|------------------|
| `ssh postgres "systemctl status postgresql"` | `maude-call.sh localhost:9201 service_status` |
| `ssh collector "journalctl -u collector"` | `maude-call.sh localhost:9206 service_logs` |
| `ssh grafana "curl localhost:3000/api/health"` | `maude-call.sh localhost:9204 grafana_health` |
| Running psql via SSH for queries | Use `mcp__postgres__query` or pg Maude tools |

---

## Troubleshooting

If a Maude tool returns empty results or errors:

1. **Check service is running:** `maude-call.sh <host:port> service_health`
2. **Check for SSH key issues:** Domain tools that use SSHExecutor need `/root/.ssh/id_ed25519` on the LXC
3. **Check executor_mode:** If config.yaml is missing `executor_mode: local`, domain tools try to SSH to themselves
4. **Check logs:** `maude-call.sh <host:port> service_errors`

**Known issue:** Some Maude configs default to `executor_mode: ssh` but run locally on the LXC. If domain tools return empty, add `executor_mode: local` to the project's `config.yaml`.
