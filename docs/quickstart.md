<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Quick Start — Room in 5 Minutes

## 1. Install

```bash
pip install maude-claude          # Core: Room toolkit + governance
pip install maude-claude[memory]  # + 4-tier memory (PostgreSQL + Qdrant)
pip install maude-claude[healing] # + Self-healing health loops
pip install maude-claude[all]     # Everything
```

For a minimal Room with just ops tools and no external databases, the base package is sufficient.

---

## 2. Create `config.yaml`

```yaml
project: my-room
service_name: my-room.service
mcp_port: 9900
ctid: 100
ip: "127.0.0.1"
description: "My first Maude Room"
executor_mode: local

# Optional: enable health loop
health_loop:
  enabled: true
  interval_seconds: 300
  max_restart_attempts: 3
  restart_cooldown_seconds: 600
  uptime_kuma_url: ""        # leave empty to skip heartbeat

# Optional: enable Room Agent (requires [healing])
# room_agent:
#   enabled: true
#   model: "qwen3-32b"
#   schedule_seconds: 3600
#   max_iterations: 10
```

The `project` field is the Room's identity throughout the system — it appears in audit logs, relay messages, memory records, and kill switch paths.

---

## 3. Create `server.py`

```python
from fastmcp import FastMCP

from maude.memory.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.ops import register_ops_tools
from maude.daemon.runner import run_room


def create_server(config: RoomConfig) -> FastMCP:
    """Create the Room MCP server from config."""
    mcp = FastMCP(
        name=f"{config.project.title()} Room",
        instructions=(
            f"MCP server for {config.service_name} "
            f"(CTID {config.ctid}, {config.ip}). "
            f"{config.description}"
        ),
    )
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    # Registers 11 standard ops tools:
    # service_status, service_health, service_logs, service_errors,
    # service_log_patterns, service_trends, service_restart,
    # service_log_cleanup, kill_switch_status, kill_switch_activate,
    # kill_switch_deactivate
    register_ops_tools(
        mcp, executor, audit, kill_switch,
        config.service_name, config.project,
        ctid=config.ctid, ip=config.ip,
    )

    # Add your own domain tools here:
    @mcp.tool()
    async def hello(name: str = "World") -> str:
        """Say hello from this Room."""
        return f"Hello, {name}! I am the {config.project} Room."

    return mcp


def main() -> None:
    run_room(create_server)
```

`run_room()` handles argument parsing (`--config`, `--port`, `--transport`, `--log-level`), logging setup, config loading, and server startup. Your `create_server` function only needs to compose tools.

---

## 4. Create `__main__.py`

```python
from my_room.server import main

main()
```

Two lines. This lets you run the Room as a module.

---

## 5. Run

```bash
# HTTP server on :9900 (default transport for autonomous daemons)
python -m my_room

# Specify config path and port
python -m my_room --config /etc/my-room/config.yaml --port 9901

# stdio transport (for Claude Desktop / Claude Code direct connection)
python -m my_room --transport stdio

# Debug logging
python -m my_room --log-level DEBUG
```

The server starts and logs:

```
2026-03-28 10:00:00 maude.daemon.runner               INFO  Starting my-room room (CTID 100, port 9900, transport streamable-http)
```

---

## 6. Connect

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or equivalent:

```json
{
  "mcpServers": {
    "my-room": {
      "command": "python",
      "args": ["-m", "my_room", "--transport", "stdio"]
    }
  }
}
```

### Claude Code (HTTP, recommended for autonomous daemons)

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "my-room": {
      "type": "http",
      "url": "http://localhost:9900/mcp"
    }
  }
}
```

### Any MCP client

The Room speaks the MCP protocol over streamable-HTTP at `http://<host>:<port>/mcp`. List available tools with a standard MCP `tools/list` call.

---

## 7. Next Steps

### Add 4-tier Memory

```bash
pip install maude-claude[memory]
```

```python
from maude.memory.memory_tools import register_memory_tools

# In create_server(), after register_ops_tools():
register_memory_tools(mcp, audit, config.project)
```

This adds 8 memory tools: `memory_store`, `memory_recall_recent`, `memory_recall_similar`, `memory_embed`, `memory_brief`, `memory_save`, `memory_recall_by_id`, `room_query`.

Memory writes local-first to SQLite, promotes to PostgreSQL, embeds to Qdrant. Each tier degrades gracefully if the next is unavailable.

### Add a Health Loop

Enable in `config.yaml`:

```yaml
health_loop:
  enabled: true
  interval_seconds: 300
  max_restart_attempts: 3
  restart_cooldown_seconds: 600
```

`run_room()` detects the flag and calls `run_with_lifecycle()` automatically. No code change needed.

### Add Governance

Governance hooks run at pre-commit time. Install the constitution:

```bash
pip install maude-claude[all]
python -m maude.governance.install --project my-room
```

This installs the template constitution, pre-commit hooks (authorship header enforcement, credential leak prevention), and the audit schema migration.

### Add A2A Relay

```python
from maude.daemon.relay_tools import register_relay_tools

# In create_server():
register_relay_tools(mcp, audit, config.project)
```

Adds `relay_send`, `relay_accept`, `relay_update`, `relay_tasks`. Messages are stored in `relay_tasks` (PostgreSQL) and cross-site routing uses `"site/room"` notation.

### Deploy as a Systemd Service

```bash
# Use the fleet deploy script
~/projects/maude/scripts/deploy-fleet.sh --room my-room

# Or the Room can self-deploy (register_deploy_tools adds these MCP tools)
# self_deploy, self_update, deploy_status
```
