<!-- Version: 3.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-03-29 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Changelog

All notable changes to Maude are documented here.

---

## v1.1.0 — Making Maude Whole (2026-03-29)

> *The framework finds its real name.*

### Rebrand

All modules renamed to functional names. Package published as `maude-claude`, import as `maude`.

| Module | Purpose |
|--------|---------|
| `maude.daemon` | Room toolkit |
| `maude.governance` | Constitution, standards |
| `maude.memory` | 4-tier memory + audit |
| `maude.healing` | Self-healing |
| `maude.coordination` | Cross-room relay |
| `maude.control` | Control plane |
| package root | Config authority |

### Config Authority Promoted

Maude's configuration authority (sweep, hooks, plans, resolve, memory budget, CLAUDE.md validation) is now at the package root:

```python
from maude import sweep, MaudeConfig, validate_claude_md
```

### Cleanup

- Removed backward-compatibility shims
- Updated all 121 source files, 70 test files, 4 examples, template

---

## v1.0.0 — First Release (2026-03-28)

> *Extracted from production infrastructure managing 21 autonomous Rooms across 4 physical sites.*

### Modules

- **daemon** (`maude.daemon`) — Room toolkit. Composition-based MCP tool registration. `run_room()` entry point. 11 standard ops tools.

- **governance** (`maude.governance`) — Governance-as-code. Constitutional framework with 11 articles. Bill of Rights. 6 federal standards. 7 enforcement hooks.

- **memory** (`maude.memory`) — 4-tier memory + audit with graceful degradation. Tier 1: knowledge files. Tier 1.5: SQLite (FTS5). Tier 2: PostgreSQL. Tier 3: Qdrant vectors. Each tier independent.

- **healing** (`maude.healing`) — Self-healing health loops with closed-loop learning. Background monitoring, semantic recall, remediation, training pipeline.

- **coordination** (`maude.coordination`) — Cross-room coordination. A2A relay messaging. Fleet deployment. Event correlation. Web dashboard.

- **Config authority** (package root) — Sweep, hooks, plans, memory budget, CLAUDE.md validation, infrastructure resolution.

### Architecture

- **Conditional imports** — Core installs without asyncpg, asyncssh, or qdrant-client
- **SQLite default** — Memory works out of the box
- **Environment-driven config** — All endpoints via `MAUDE_*` env vars
- **Zero-infrastructure quickstart** — `pip install maude-claude` and 10 lines of Python

### Packaging

- Python package: `maude-claude` (import as `maude`)
- Optional extras: `[memory]`, `[healing]`, `[ssh]`, `[web]`, `[cache]`, `[training]`, `[all]`
- Build: hatchling
- License: Apache 2.0

### Examples

- `hello-room` — Minimal Room, zero infrastructure
- `memory-room` — SQLite memory, store and recall
- `healing-room` — Health loop with auto-healing
- `governed-room` — Guards, kill switch, audit trail
