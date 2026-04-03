<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Configuration Reference

Complete reference for `config.yaml` and environment variables in the Maude framework.

---

## config.yaml

Every room carries a `config.yaml` that maps to the `RoomConfig` dataclass
(`src/maude/daemon/config.py`). The loader ignores unknown keys, so
room-specific YAML can carry extra fields without breaking the loader. The
key `port` is accepted as an alias for `mcp_port` for backward compatibility.

### Identity Fields

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `project` | string | yes | Project identifier — matches directory and systemd unit name |
| `service_name` | string | yes | Systemd service name for the application managed by this room |
| `mcp_port` | int | yes (default: 9900) | Streamable HTTP port the MCP server listens on |
| `ctid` | int | no (default: 0) | Proxmox LXC container ID |
| `ip` | string | no | LXC IP address (expected to match `10.x.x.x` pattern) |
| `executor_mode` | string | no (default: `"local"`) | `"local"` runs commands via subprocess on the same LXC; `"ssh"` runs via asyncssh to `ssh_alias` |
| `description` | string | no | Human-readable room description |
| `database` | string | no | Default PostgreSQL database for domain queries (e.g., `"plc"`, `"agent"`) |

### health_loop

Background health monitor with automatic restart capability.

```yaml
health_loop:
  enabled: true
  interval_seconds: 300         # Seconds between checks (default: 300)
  max_restart_attempts: 3       # Restarts before giving up (default: 3)
  cooldown_seconds: 600         # Seconds between restart attempts (default: 600)
  health_endpoint: "http://localhost:8080/api/health"
  heartbeat_url: ""             # Uptime Kuma push URL (optional)
```

Set `max_restart_attempts: 0` to disable automatic restarts entirely — the
health loop will still run checks and escalate to the room agent, but will
never restart the service autonomously.

### room_agent

LLM-powered autonomous agent for self-healing and diagnostics. Requires
`pip install maude-claude[llm]`.

```yaml
room_agent:
  enabled: true
  name: my-service
  knowledge_dir: .maude/              # Tier 1 — markdown knowledge files
  max_iterations: 10
  max_tokens: 4096

  scheduled_tools:
    - service_health

  tools:
    - service_status
    - service_health
    - service_logs
    - service_errors
    - service_restart

  memory:
    postgresql: true
    qdrant: true
    recent_limit: 10
    similar_limit: 5

  llm:
    vllm:
      model: Qwen/Qwen3-32B
      temperature: 0.2

  git:
    enabled: true
    remote: origin
    branch: main
    auto_pull: true
    auto_push: true

  triggers:
    - type: health_loop_escalation
    - type: schedule
      interval_seconds: 3600
```

### local_memory

SQLite-backed sovereign memory (Tier 1.5). Persists at
`/var/lib/maude/{project}/memory.db`.

```yaml
local_memory:
  enabled: true
  sync_up_interval: 60          # Seconds between SQLite → PG sync
  sync_down_interval: 300       # Seconds between PG → SQLite cache refresh
  privacy:
    default_scope: patterns     # "patterns", "incidents", or "all"
    share_incidents: false
    share_patterns: true
```

### events

PostgreSQL NOTIFY publisher for cross-room coordination.

```yaml
events:
  enabled: false
  backend: pg                   # "pg" or "redis"
  db_host: ""                   # Override; empty = from credentials
  database: agent
```

### redis

Optional Redis client for distributed rate limiting and event streaming.
Requires `pip install maude-claude[cache]`. Gracefully degrades if
unavailable.

```yaml
redis:
  enabled: false
  host: ""                      # Empty = from credentials or localhost
  port: 6379
  db: 0
```

### acl

Access control list for tool authorization. Rooms can restrict which callers
may invoke which tools.

```yaml
acl:
  enabled: false
  default_policy: allow         # "allow" or "deny"
  rules: []
```

---

## Environment Variables

The framework resolves infrastructure hosts through a priority chain:
**environment variable > `~/.credentials/secrets.yaml` > default**.

The credentials path itself is controlled by `MAUDE_CREDENTIALS_PATH`.

| Variable | Description | Default |
|----------|-------------|---------|
| `MAUDE_CREDENTIALS_PATH` | Path to the credentials file | `~/.credentials/secrets.yaml` |
| `MAUDE_DB_HOST` | PostgreSQL host | From credentials -> `localhost` |
| `MAUDE_DB_PORT` | PostgreSQL port | From credentials |
| `MAUDE_DB_NAME` | PostgreSQL database name | `"agent"` |
| `MAUDE_QDRANT_URL` | Qdrant base URL | From credentials -> `localhost` |
| `MAUDE_EMBEDDER_URL` | Embedder (vLLM) base URL | From credentials -> `localhost:8001` |
| `MAUDE_EMBEDDER_MODEL` | Embedding model name | `"BAAI/bge-large-en-v1.5"` |
| `MAUDE_HOME` | Base path for storage | `/var/lib/maude/` |
| `MAUDE_TRAINING_HOME` | Training data root directory | From credentials |
| `MAUDE_BASE_MODEL` | Base model for fine-tuning | From credentials |
| `MAUDE_ORG_NAME` | Organization name for model registry | From credentials |
| `MAUDE_GITEA_ORG` | Gitea organization for model pushes | From credentials |

Additionally, several `MAUDE_*` variables control low-level framework
behavior and are used internally by `common.py`:

| Variable | Description |
|----------|-------------|
| `MAUDE_REDIS_HOST` | Redis host override |
| `MAUDE_QDRANT_HOST` | Qdrant host override |
| `MAUDE_VLLM_HOST` | Primary vLLM host |
| `MAUDE_VLLM_HOSTS` | Comma-separated list of vLLM hosts for active-active failover |
| `MAUDE_EMBEDDER_HOSTS` | Comma-separated list of embedder hosts for failover |
| `MAUDE_EMBEDDING_MODEL` | Embedding model name override |
| `MAUDE_EMBEDDING_DIM` | Embedding vector dimension (default: `1024`) |
| `MAUDE_EMBED_CACHE_SIZE` | In-process LRU embedding cache size (default: `256`) |

---

## Two Deployment Paths

### Zero Infrastructure

No external services required. Suitable for local development or simple
standalone rooms.

```bash
pip install maude-claude
```

Create a minimal `config.yaml`:

```yaml
project: my-service
service_name: my-service
mcp_port: 9900
```

Memory degrades gracefully: SQLite local store only, stdout audit log,
no PostgreSQL or Qdrant. The `register_memory_tools()` call still works —
it returns local-only results from SQLite and skips PG/Qdrant calls silently.

### Full Stack

All three memory tiers active. Start the development stack:

```bash
docker compose up -d
```

This brings up PostgreSQL on :5432, Qdrant on :6333, and Redis on :6379
with development credentials (`maude` / `maude-dev`).

Then install with all extras:

```bash
pip install "maude[memory,llm,cache]"
```

With the full stack running, `memory_store()` writes to SQLite first, then
promotes to PostgreSQL, and `memory_recall_similar()` uses Qdrant cosine
search. The SyncWorker runs in the background to keep tiers in sync.
