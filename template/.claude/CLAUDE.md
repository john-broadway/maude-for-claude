# CLAUDE.md — {{PROJECT}}

> **Version:** 1.0
> **Updated:** {{DATE}}

## Container

| Field | Value |
|-------|-------|
| CTID | {{CTID}} |
| IP | {{IP}} |
| SSH | `ssh {{SSH_ALIAS}}` |
| Service | `maude@{{PROJECT}}.service` |
| MCP Port | {{MCP_PORT}} |

## Architecture

**Package:** `{{PROJECT}}_mcp` in `src/{{PROJECT}}_mcp/`
**Transport:** Streamable HTTP on :{{MCP_PORT}}/mcp (autonomous on CTID {{CTID}})
**Service:** `maude@{{PROJECT}}.service` (systemd daemon on CTID {{CTID}})
**Pattern:** Function composition — no inheritance

`server.py` composes `FastMCP` + `LocalExecutor` + `AuditLogger` + `KillSwitch`, then registers tool groups:

| Registration | Count | Source |
|-------------|-------|--------|
| `maude.daemon.ops.register_ops_tools` | 11 | Standard ops (status, health, logs, errors, restart, kill switch) |
| `maude.memory.memory_tools.register_memory_tools` | 8 | Four-tier memory (knowledge, SQLite, PostgreSQL, Qdrant) |

**Health loop:** 300s interval, 3 restart attempts, 600s cooldown. Uptime Kuma heartbeat push.

**Room Agent:** Qwen3-32B on vLLM, 3600s schedule, 10 max iterations. Scheduled tools: `service_health`.

**Config:** `src/{{PROJECT}}_mcp/config.yaml` — `executor_mode: local` (MCP runs ON the LXC).

## Key Files

| File | Purpose |
|------|---------|
| `src/{{PROJECT}}_mcp/server.py` | MCP server — `create_server()` composes all tools |
| `src/{{PROJECT}}_mcp/__main__.py` | Entry point for `python -m {{PROJECT}}_mcp` |
| `src/{{PROJECT}}_mcp/config.yaml` | Room config (service, health loop, room agent, events) |
| `src/{{PROJECT}}_mcp/tools/` | Domain-specific MCP tools |
| `.maude/identity.md` | Room identity for Room Agent |
| `pyproject.toml` | Package config |
| `tests/` | Domain tool + server tests |

## Domain Tools

> Maude base tools (11 ops + 8 memory): see `~/.claude/reference/maude-interaction.md`

## Build & Test

```bash
pip install -e ".[dev]"
pytest tests/ -v
ruff check src/
```

## Deployment

```bash
# Dry run
~/projects/maude/scripts/deploy-fleet.sh --room {{PROJECT}} --dry-run

# Deploy
~/projects/maude/scripts/deploy-fleet.sh --room {{PROJECT}}
```

## Constraints

- **MCP first:** Per-project MCP > SSH

## Related Projects

| Project | Relationship |
|---------|-------------|
| `~/projects/maude/` | Maude daemon framework |
| `~/projects/infrastructure/` | Host infrastructure |
