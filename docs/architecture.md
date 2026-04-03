<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Maude — Architecture

## The 5 Novel Contributions

| # | Contribution | What it solves |
|---|--------------|----------------|
| 1 | **Governance-as-code** | Constitutional rules, enforcement hooks, and audit trails are first-class framework artifacts — not afterthoughts bolted on externally |
| 2 | **Sovereign autonomous daemons** | Each Room is an independent, self-contained daemon with its own memory, kill switch, and health loop; no shared mutable state between rooms |
| 3 | **Composition over inheritance for MCP** | Tool groups (`register_ops_tools`, `register_memory_tools`, etc.) are plain functions that stamp tools onto a `FastMCP` instance — no base classes, no mixins |
| 4 | **4-tier memory with graceful degradation** | Files → SQLite → PostgreSQL → Qdrant form an independent stack; losing any tier degrades capability without losing functionality |
| 5 | **Closed-loop learning** | Health events become PostgreSQL records, become Qdrant embeddings, inform future Room Agent decisions. LoRA training pipeline distills, fine-tunes, validates, and canary-deploys — full closed loop |

---

## Module Map

| Module | Purpose |
|--------|---------|
| `maude.daemon` | Room daemon toolkit: config loading, ops tools, guards, audit logger, kill switch, executor, relay tools, runner |
| `maude.governance` | Governance engine: constitution, standards, enforcement hooks |
| `maude.memory` | Memory + audit: 4-tier memory (`KnowledgeManager`, `LocalStore`, `MemoryStore`, `SyncWorker`) + `AuditLogger` (every tool call permanent) |
| `maude.healing` | Self-healing: `HealthLoop` (rule-based restarts), `RoomAgent` (LLM diagnostics), `lifecycle.run_with_lifecycle()`, training pipeline |
| `maude.coordination` | Cross-room coordination: fleet deploy, Relay messaging, event bus, cross-site memory, briefing, web UI |
| `maude.control` | Control plane sidecar: emergency response, fleet deployment, operator tools |
| `maude.middleware` | Doorman middleware: ACL enforcement + interaction logging on every inbound MCP call |
| `maude.coordination.relay` | A2A task state machine: `pending -> accepted -> running -> completed/failed` stored in `relay_tasks` table |
| `maude.infra.events` | Event routing: PG NOTIFY on `maude_events` or Redis Streams |
| `maude.daemon.deploy` | Self-deploy tools: rooms pull their own code from Gitea, update the library, report status |

---

## How Rooms Work

A Room is a `FastMCP` HTTP server running as a systemd daemon on its own LXC. The entry point is always `run_room()`.

```
run_room(create_server)
    │
    ├── parse_args()                      # --config, --port, --transport, --log-level
    ├── RoomConfig.from_yaml(path)        # Load + validate config.yaml
    ├── factory(config) → FastMCP         # Your create_server() function
    ├── register_card_resource(mcp, config) # room://card capability advertisement
    │
    └── if health_loop or room_agent enabled:
            run_with_lifecycle(mcp, config, ...)
                ├── LocalExecutor()           # Run commands on this LXC
                ├── AuditLogger(project)      # PostgreSQL + stdout audit
                ├── KillSwitch(project)       # /var/lib/maude/<project>/readonly
                ├── _wire_middleware()        # ConciergeServices: ACL + audit
                ├── HealthLoop.start()        # 300s interval, auto-restart, heartbeat
                ├── RoomAgent.start()         # LLM agent (schedule + event-triggered)
                ├── EventPublisher.connect()  # PG NOTIFY maude_events
                └── mcp.run(transport, host, port)
        else:
            mcp.run(transport, host, port)   # Bare MCP server, no background tasks
```

### Daemon Lifecycle Decision Tree

```
Health Loop (every 300s):
  1. Kill switch active?          → skip restart, log warning
  2. Domain checks: upstream_issue? → skip restart, log upstream
  3. Service down?                → systemctl restart <service>
  4. Health endpoint unhealthy?   → restart
  5. Error spike (>10 in 5min)?   → restart
  6. Memory > 90%?                → restart
  7. Disk > 80%?                  → escalate (log, no restart)
  8. All clear                    → Uptime Kuma heartbeat "up"

Rate limit: max 3 restarts/hour, 10min cooldown per restart.
```

---

## The Composition Pattern

Tools are registered by calling functions on a `FastMCP` instance. No base classes. No inheritance. Each `register_*` function closes over the dependencies it needs.

```python
def create_server(config: RoomConfig) -> FastMCP:
    mcp = FastMCP(name=f"{config.project.title()} Room")
    executor = LocalExecutor()
    audit    = AuditLogger(project=config.project)
    ks       = KillSwitch(project=config.project)

    # 11 standard ops tools (status, health, logs, errors, restart, kill switch...)
    register_ops_tools(mcp, executor, audit, ks,
        config.service_name, config.project,
        ctid=config.ctid, ip=config.ip)

    # 2 MCP resources (room://status, room://config)
    register_ops_resources(mcp, executor, config.service_name, config.project,
        ctid=config.ctid, ip=config.ip,
        mcp_port=config.mcp_port, config=config)

    # 8 per-room memory tools (store, recall, embed, search...)
    register_memory_tools(mcp, audit, config.project)

    # 3 deploy tools (self_deploy, self_update, deploy_status)
    register_deploy_tools(mcp, executor, audit, ks,
        config.project, service_name=config.service_name)

    # 4 A2A relay tools (relay_send, relay_accept, relay_update, relay_tasks)
    register_relay_tools(mcp, audit, config.project)

    # Your domain tools — same pattern
    register_my_domain_tools(mcp, executor, audit)

    return mcp
```

Each `register_*` function registers one or more `@mcp.tool()` decorated async functions. The decorators stack in a fixed order:

```python
@mcp.tool()
@audit_logged(audit)          # always outermost — log every call
@requires_confirm(kill_switch) # check kill switch + require confirm=True + reason
@rate_limited(min_interval_seconds=120.0)
async def service_restart(confirm: bool = False, reason: str = "") -> str:
    ...
```

Read-only tools: `@audit_logged` only.
Write/mutating tools: `@audit_logged` + `@requires_confirm` + `@rate_limited`.

---

## Memory Tiers

```
Tier 1 — Markdown files
  .maude/knowledge/*.md
  KnowledgeManager
  (identity, static knowledge, constitution, room profile)
       |
       | always available — local filesystem
       v
Tier 1.5 — SQLite local store
  /var/lib/maude/<project>/memory.db
  LocalStore (FTS5 full-text search)
  (structured local memory, relay outbox buffer)
       |
       | available if PostgreSQL is reachable
       v
Tier 2 — PostgreSQL shared memory
  agent.memories table
  MemoryStore.store() / .recall_recent()
  (cross-room shared memory, audit log, relay tasks)
       |
       | available if Qdrant is reachable
       v
Tier 3 — Qdrant vector search
  MemoryStore.embed() / .recall_similar()
  nvidia/llama-nemotron-embed-1b-v2 (1024-dim)
  (semantic recall: "find memories similar to this incident")

Graceful degradation:
  Qdrant down  → fall back to PostgreSQL FTS
  PG down      → fall back to SQLite FTS5
  SQLite down  → fall back to file knowledge only
  Writes:      → local-first, promote via SyncWorker
```

---

## Governance Enforcement Chain

```
Constitution (.md articles)
    │   Supreme law — non-negotiable principles
    │
    ▼
Federal Standards (agency/standards/)
    │   Code quality, testing, config, logging conventions
    │
    ▼
Pre-commit Hooks (maude.governance.hooks)
    │   Authorship header, credential leak prevention,
    │   constitution/standards version checks
    │
    ▼
Guard Decorators (maude.daemon.guards)
    │   @requires_confirm  — explicit consent for mutations
    │   @rate_limited      — prevent rapid-fire writes
    │   @audit_logged      — every call recorded
    │
    ▼
Kill Switch (/var/lib/maude/<project>/readonly)
    │   File-based circuit breaker — blocks all writes
    │   Activated manually or by health loop escalation
    │
    ▼
Audit Log (agent_audit_log + Loki)
    Immutable, append-only. Project, tool, caller, params,
    result summary, duration, reason — every call.
```

---

## Cross-Room Coordination

### Coordination Layer

The coordination layer (`maude.coordination`) manages cross-room communication without entering any Room's territory. It runs as its own daemon and exposes:

- **Fleet deploy** — signals rooms to self-deploy via relay messages and PG events
- **Cross-room memory** — reads `agent.memories` for any room (with scope controls)
- **Briefing** — synthesizes recent incidents and decisions across all rooms
- **Web UI** — dashboard showing room health, relay inbox, governance status

### Relay Messaging (A2A)

Inter-room tasks flow through the `relay_tasks` PostgreSQL table:

```
Room A                         relay_tasks (PG)            Room B
  │                                  │                        │
  ├─ relay_send("room-b", ...)  ─────► INSERT pending         │
  │                                  │                        │
  │                                  ◄── relay_tasks poll ────┤
  │                                  │                        ├─ relay_accept(task_id)
  │                                  │   UPDATE accepted      │
  │                                  │                        ├─ ... do work ...
  │                                  │                        ├─ relay_update(completed)
  │                                  │   UPDATE completed     │
```

State machine: `pending → accepted → running → completed / failed`
Cross-site: `CrossSiteRelay` routes bare room names locally, `"site/room"` notation over HTTP.

### Event Bus

`EventPublisher` fires PG NOTIFY on `maude_events` (or Redis Streams). The health loop and room agent both publish events. The coordination layer's `EventListener` subscribes and routes to interested parties.

### Fleet Deployment

`register_fleet_deploy_tools` on the coordination daemon publishes a deploy event and relay message to each room. Rooms with `register_deploy_tools` handle the message by calling `git pull` + `pip install` + `systemctl restart`. No SSH push required.
