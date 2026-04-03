<!-- Version: 2.0.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-03-29 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# CLAUDE.md — Maude for Claude

> **Version:** 3.0.0
> **Status:** Public, scrubbed, CI-gated
> **License:** Apache 2.0, Copyright John Broadway

## What This Is

Autonomous agent framework for infrastructure operations. Extracted from a production system managing 21+ Rooms across 4 physical sites. Not a chatbot framework — this builds daemons that detect, heal, and learn 24/7.

**PyPI name:** `maude-claude` | **Import:** `maude` | **Python:** 3.10+
**Built on:** FastMCP 3.x, httpx, PyYAML (core). PostgreSQL, Qdrant, Redis optional.

## Architecture

| Module | What It Does |
|--------|-------------|
| `maude.daemon` | Room daemon toolkit — config, runner, executor, guards, kill switch, session, deploy |
| `maude.governance` | Governance — constitution, standards, enforcement hooks |
| `maude.memory` | Memory + audit — 4-tier memory, audit log, the entire information system |
| `maude.healing` | Self-healing — health_loop, lifecycle, room_agent, training pipeline |
| `maude.coordination` | Cross-room coordination — relay, fleet deploy, briefings, web dashboard |
| `maude.control` | Control plane sidecar — emergency response, fleet deployment, operator tools |
| `maude` (root) | Configuration authority — drift detection, config resolution, standards. Also ships as Claude Code skill |
| `maude.analysis` | Trend analysis, anomaly detection |
| `maude.auth` | OIDC authentication |
| `maude.db` | Connection pooling (asyncpg) |
| `maude.eval` | Benchmarks, scoring |
| `maude.infra` | Event system, Redis client |
| `maude.llm` | vLLM router, guardrails, token counting |
| `maude.middleware` | ACL, concierge, guest book |
| `maude.testing` | Test fakes and helpers |

## Source Layout

```
src/maude/                # Package root + config authority
  config.py               # MaudeConfig — path resolution, auto-detection
  sweep.py                # Full configuration sweep orchestrator
  hooks.py                # Hook inventory and validation
  plans.py                # Plan hygiene auditing
  memory_budget.py        # MEMORY.md budget enforcement
  claude_md.py            # CLAUDE.md quality validation
  resolve.py              # Infrastructure host + credential resolution
  daemon/                 # Room daemon: config, runner, executor, guards, kill_switch, session, deploy
  memory/                 # Memory + audit: local_store, store, knowledge, sync, consolidation, audit
  healing/                # Self-healing: health_loop, lifecycle, room_agent, training/
  coordination/           # Coordination: relay, fleet, briefing, mcp, web/ (FastAPI dashboard)
  governance/             # Governance (constitution, standards, hooks)
  analysis/               # log_analyzer, trend_analyzer
  auth/                   # OIDC
  db/                     # PostgreSQL pool, formatting
  eval/                   # benchmark, score
  infra/                  # events, redis_client
  llm/                    # vLLM router, guardrails, tokens
  middleware/             # ACL, concierge, guest_book
  testing.py             # Test helpers and fakes
tests/                   # 72 test files (1465 passing)
docs/                    # architecture, characters, config, governance, memory, quickstart
examples/                # hello-room, memory-room, healing-room, governed-room
skills/maude/            # Claude Code skill for configuration authority
template/                # Starter project template (copy and rename)
```

## Key Patterns

### Room Composition (not inheritance)
Rooms compose tools via `register_*_tools()` functions. No base classes. Each function gives you a set of MCP tools:
- `register_ops_tools()` — 11 standard ops tools (daemon)
- `register_memory_tools()` — memory CRUD (memory)
- Custom tools via `mcp.tool()` as usual with FastMCP

### Config
`config.yaml` at project root. Loaded by `RoomConfig` (daemon.config). Key fields:
- `project`, `service_name`, `mcp_port`, `room_id`, `ip`
- Health loop, memory, and credential settings are nested

### Entry Point
`run_room(create_server)` in daemon.runner boots the daemon. Your `create_server` function takes a `RoomConfig`, returns a `FastMCP`.

### Guards
`@requires_confirm`, `@rate_limited` decorators. Kill switch blocks all guarded writes.

### Conditional Imports
Core (`pip install maude-claude`) works with zero infrastructure. Extras:
- `[memory]` — asyncpg + qdrant-client
- `[healing]` — memory extras (health loop stores incidents)
- `[ssh]` — asyncssh for remote execution
- `[web]` — FastAPI dashboard
- `[cache]` — Redis
- `[all]` — everything

## Locked Decisions

These are NOT up for debate — decided by John Broadway:

1. **Maude is the name** — Claude and Maude, husband and wife at work.
2. **John Broadway owns copyright** — independent creator, disabled veteran.
3. **Claude acknowledged in README** but NOT in pyproject.toml authors (AI can't hold copyright)
4. **fastmcp >=3.0.0,<4** — 2.x pin was broken, fixed during extraction
5. **Conditional imports** — core must install with zero infrastructure
6. **SQLite default** memory (local_store) — no mandatory PG/Qdrant
7. **Maude IS the package** — config authority lives at the package root. `from maude import sweep`
8. **Functional module names** — daemon, governance, memory, healing, coordination, control

## Origin Scrub — NEVER Reintroduce

This repo was extracted from production and fully scrubbed on 2026-04-01. **Nothing from the production origins may appear in this repo.** The CI gate enforces this automatically.

### Naming conventions (public repo)
| Concept | Public name | NOT this |
|---------|------------|----------|
| Env var prefix | `MAUDE_*` | ~~CHARON_~~ |
| Coordinator | `coordinator` | ~~Front Desk~~ |
| Config dir | `.maude/` | ~~.charon/~~ |
| Example IPs | `192.0.2.x`, `198.51.100.x`, `203.0.113.x` | ~~10.10.0.x~~ |
| Example sites | `site-a`, `site-b`, `site-c` | ~~HP-SLC, HP-PA, SBM~~ |
| Example services | `example-scada`, `lab-service`, `ehs-service` | ~~aurum, assay, aegis~~ |

### Scrub pipeline
- `scripts/scrub-patterns.txt` — single source of truth for all forbidden patterns
- `scripts/scrub-check.sh` — local gate (`make scrub`)
- `.github/workflows/ci.yml` — CI gate (reads same patterns file, hard blocks PRs)
- Both gates exclude only themselves, scan each other (mutual surveillance)

### Cherry-pick from production
1. Cherry-pick commit into a feature branch
2. `make scrub` — fix any flagged patterns
3. Open PR — CI blocks if scrub fails
4. Production-to-public translation: `~/scripts/translate-to-production.sh` (lives on production box, NOT in this repo)

### Branch protection
- `enforce_admins: true` — even owner needs CI to pass
- Required checks: `scrub`, `test (3.12)`
- No force push, no branch deletion

## Known Issues

- #1: Sync bookkeeping failure can cause duplicate PG rows or missed Qdrant embeddings
- #3: Embedding cache doesn't invalidate on model change

All 1,465 tests pass on Python 3.10-3.13. Zero warnings. CI is live at GitHub Actions.

## Development

```bash
# Install in dev mode
pip install -e ".[dev,all]"

# Run all checks (lint + scrub + test)
make all

# Run individually
make lint         # ruff check
make scrub        # origin scrub check
make test         # pytest

# Run an example
cd examples/hello-room && python -m hello_room
```

## What's Next

- [x] Create GitHub repo and push — `github.com/john-broadway/maude-for-claude`
- [x] Fix test_server.py for FastMCP 3.x — migrated to `local_provider._components`
- [x] CI/CD — GitHub Actions on Python 3.10-3.13
- [x] Origin scrub — all internal references removed
- [x] Scrub pipeline — CI hard gate + cherry-pick workflow
- [x] Branch protection — enforce_admins, required checks
- [ ] PyPI publish (`python -m build && twine upload dist/*`)
- [ ] Fix #1 — idempotent sync bookkeeping
- [ ] Fix #3 — include model name in embedding cache key

## Origin

Extracted 2026-03-28 from production infrastructure. Fully scrubbed 2026-04-01 (104 files, 1,737 lines removed). GitHub repo deleted and recreated with clean single-commit history. Claude and Maude — the real story.
