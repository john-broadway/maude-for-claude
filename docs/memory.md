<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Memory System

The four-tier memory system gives every room a persistent, queryable
record of what has happened, what patterns have been learned, and what
decisions have been made — surviving partial infrastructure failure at each
step.

---

## Architecture Overview

```
Tier 1: Knowledge Files (.md)
  identity.md, skills/*.md, memory/patterns.md
  Git-tracked. Loaded into system prompt at startup.
  Source of truth for room identity and standing instructions.

Tier 1.5: SQLite (Local Sovereign Memory)
  /var/lib/maude/{project}/memory.db
  FTS5 full-text search. WAL mode for concurrent reads.
  Zero external dependencies. Default write target — always written first.

Tier 2: PostgreSQL
  Database: agent / Table: agent_memory
  Shared across rooms. Structured recall by type and time.
  Authoritative read source when available.

Tier 3: Qdrant
  Collection: room_memory_{project}
  Vector embeddings (1024-dim cosine). Semantic similarity search.
  Also writes to shared "vault" collection for cross-room recall.
```

---

## Tier 1: Knowledge Files

Markdown files in the room's knowledge directory (`.maude/` by convention).
They carry:

- **identity.md** — who the room is, what it manages, operational mandate
- **skills/*.md** — playbooks for specific diagnostic or remediation tasks
- **memory/patterns.md** — accumulated learned patterns (git-tracked)
- **memory/incidents.md** — notable incident summaries for human review
- **memory/preferences.md** — operational preferences and standing decisions

These files are git-tracked. When `room_agent.git.auto_pull: true`, the room
agent pulls the latest knowledge before each agent run. When `auto_push: true`,
memory updates are pushed back so knowledge accumulates across sessions.

`memory_load_knowledge()` reads all `.md` files from the knowledge directory
and returns their concatenated content as a single string, suitable for
injection into a system prompt.

---

## Tier 1.5: SQLite (Local Sovereign Memory)

Stored at `/var/lib/maude/{project}/memory.db`. The schema has four
tables: `memories`, `sync_queue`, `sync_state`, and `local_audit_log`.

SQLite is opened in **WAL mode**, which allows concurrent reads during
background sync writes without blocking tool calls.

**FTS5 full-text search** indexes `summary`, `trigger`, and `reasoning`
fields. This powers `room_query()` keyword search without requiring PostgreSQL
or Qdrant. When all three higher tiers are unavailable, FTS5 keeps memory
searchable.

**Write path:** Every `store_memory()` call writes SQLite first, then attempts
PostgreSQL inline. If PostgreSQL is unavailable, the record stays in SQLite
and a `sync_queue` entry is created so the SyncWorker can promote it later.

**Read path for `recall_recent()`:** PostgreSQL first (authoritative), SQLite
fallback. Local-only records get negative IDs (e.g., `-42`) to distinguish
them from PG-assigned IDs.

---

## Tier 2: PostgreSQL

Table `agent_memory` in the `agent` database. Columns include `project`,
`memory_type`, `summary`, `trigger`, `reasoning`, `outcome`, `context`
(JSONB), `actions_taken` (JSONB), `tokens_used`, `model`, `root_cause`,
and `created_at`.

PostgreSQL is the authoritative structured memory layer. `recall_recent()`
queries by `project` and optional `memory_type`, ordered by `created_at DESC`.

**Retention rules** (enforced by `prune_stale_memories()`):
- `type='check'` + `outcome='no_action'` older than 14 days — deleted
- `type='incident'` or `type='escalation'` older than 180 days — deleted
- `type='pattern'` or `type='remediation'` — never deleted

---

## Tier 3: Qdrant

One Qdrant collection per room: `room_memory_{project}`. Vectors are 1024
dimensions, cosine distance. Each point's payload includes `pg_id`, `project`,
`memory_type`, `summary`, `outcome`, `created_at`, and optional enrichment
fields (`actions_summary`, `root_cause`, `tools_used`).

Every successful `embed_and_store()` call also upserts to the shared `vault`
collection. The vault is a cross-room unified index — it receives every room's
embeddings so semantic search can span the whole fleet.

Point IDs are deterministic UUIDs derived from `maude.memory.{pg_id}`,
making all upsert operations idempotent.

Embeddings are generated via the vLLM embedder (default model:
`BAAI/bge-large-en-v1.5`). The `MemoryStore` maintains an in-process LRU
cache of up to 256 embeddings to avoid redundant API calls.

---

## Graceful Degradation

The system degrades gracefully as infrastructure becomes unavailable. At each
level, the tier below continues to function independently.

```
Qdrant unavailable
    recall_similar() returns None (callers skip Qdrant leg)
    FTS5 (SQLite) handles keyword queries
    PostgreSQL handles structured recall
    PG writes continue normally
    SQLite sync_queue buffers Qdrant work for later backfill
         |
         v
PostgreSQL unavailable
    recall_recent() falls back to SQLite
    store_memory() writes SQLite only; sync_queue entry created
    room_query() uses FTS5 directly
    Knowledge files and local audit log still work
         |
         v
SQLite unavailable
    store_memory() returns None (no local floor)
    Knowledge files (.md) still load
    Audit logger falls back to stdout-only
         |
         v
Only knowledge files remain
    memory_load_knowledge() still returns identity, skills, patterns
    No structured recall, no semantic search
    Room agent can still read its identity and playbooks
```

---

## The Sync Worker

`SyncWorker` (`src/maude/memory/sync.py`) runs as a background asyncio
task alongside the health loop.

**Sync-up (every 60 seconds by default):** Drains `sync_queue` entries from
SQLite to PostgreSQL and Qdrant. For each pending record in the queue, it
calls `store_memory()` for PG or `embed_and_store()` for Qdrant, then marks
the queue entry `complete`.

**Sync-down (every 300 seconds):** Pulls recent PostgreSQL memories into the
local SQLite cache so the local fallback stays warm even if the room hasn't
written any memories recently.

**Warm-from-PG (startup):** On first boot, if SQLite is empty, the SyncWorker
pulls a page of recent PG records into SQLite so the local FTS5 index has
content immediately.

Both intervals are configurable under `local_memory.sync_up_interval` and
`local_memory.sync_down_interval` in `config.yaml`.

---

## Cross-Room Memory

The coordination layer (`maude.coordination`) queries the `agent_memory` table
without a `project` filter, giving it visibility across all rooms in the
fleet. This is how fleet-wide patterns and incidents become visible to the
coordinator agent.

Individual rooms expose cross-room access through `room_query()` with
privacy scoping. When another room calls `room_query()`, it receives only
the records that the owning room's privacy configuration allows.

---

## Privacy Scopes

`room_query()` enforces three scopes:

| Scope | Allowed Memory Types | Intended Caller |
|-------|---------------------|-----------------|
| `"patterns"` | `pattern`, `decision` | Any caller — safe to share widely |
| `"incidents"` | `pattern`, `decision`, `incident`, `escalation` | Restricted — requires `share_incidents: true` in room config |
| `"all"` | No filter applied | Executive agents with full access |

The owning room's `local_memory.privacy.share_incidents` setting gates whether
the `"incidents"` scope is honored or silently downgraded to `"patterns"`.

---

## API: `register_memory_tools()`

`register_memory_tools(mcp, audit, project)` in
`src/maude/memory/memory_tools.py` registers 8 tools on a FastMCP
instance. All tools are project-bound at registration time — `project` is
captured via closure and never appears as a tool parameter.

| Tool | Description |
|------|-------------|
| `memory_store` | Store a structured memory (type, summary, trigger, reasoning, outcome) to SQLite and PostgreSQL |
| `memory_recall_recent` | Recall the most recent memories for this room from PostgreSQL, filtered by optional type |
| `memory_recall_similar` | Semantic search via Qdrant — returns memories ranked by cosine similarity to a query string |
| `memory_recall_by_id` | Retrieve a single memory by its PostgreSQL row ID |
| `memory_embed` | Embed an already-stored memory (by PG ID) into Qdrant for semantic recall |
| `memory_save` | One-shot convenience: `memory_store` + `memory_embed` in a single call |
| `memory_brief` | Full recall: returns recent memories from PostgreSQL (Tier 2) and semantically similar memories from Qdrant (Tier 3) based on the most recent summary |
| `memory_load_knowledge` | Load all `.md` knowledge files from the room's knowledge directory and return their concatenated content |
| `room_query` | Privacy-scoped keyword search — answers cross-room queries; tries FTS5 first, falls back to PostgreSQL |

All 8 tools are wrapped with `@audit_logged` so every memory access is
recorded to the audit trail.
