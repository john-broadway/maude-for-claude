---
title: Context Directory Schema
type: schema
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Context Directory Schema

## Purpose

Defines how `.claude/context/` directories should be structured for persistent
project context. The context directory holds project-level knowledge that
persists across work sessions but is scoped to a single project — not global. It
tracks architectural decisions, discovered gotchas, and current work state.
Without structured context, every new session starts from zero and rediscovers
the same problems.

## Required Structure

```
.claude/context/
├── decisions.md        # Architecture Decision Records (ADRs)
└── discoveries.md      # Learnings, gotchas, and corrections
```

Both files must exist. They may be empty (with just a header) in a new project, but the files must be present.

## Optional Structure

```
.claude/context/
├── session.md          # Current work session state
└── roadmap.md          # Project-specific roadmap and priorities
```

## Required Sections

### decisions.md

Architecture Decision Records. Each entry captures a decision that constrains future work. Entries are chronological, most recent first.

**Entry format:**

```markdown
### YYYY-MM-DD: {Decision Title}

**Context:** Why this decision was needed. What problem or ambiguity triggered it.

**Decision:** What was decided. Be specific — name the technology, pattern, or convention chosen.

**Consequences:** What this means going forward. What is now easier, what is now harder, what is ruled out.
```

**Rules:**
- One decision per entry. Do not bundle.
- Never delete entries. If a decision is reversed, add a new entry that references the old one.
- The title should be scannable — a developer skimming the file should understand the decision from the title alone.

**Example:**

```markdown
# Architecture Decisions

### 2026-02-12: Use TimescaleDB for PLC time-series instead of raw PostgreSQL

**Context:** PLC tag history queries were slow at scale. Considered InfluxDB (already in stack) vs. TimescaleDB (PostgreSQL extension).

**Decision:** TimescaleDB on the existing PostgreSQL instance (CTID 1030). Hypertables for `tag_history` and `alarm_history`.

**Consequences:** Single database engine for relational + time-series. No need for a separate InfluxDB writer for PLC data. Chunk compression reduces storage 5-8x. Must run `timescaledb-tune` after PostgreSQL upgrades.
```

### discoveries.md

Things learned the hard way. Gotchas, corrections, and non-obvious behaviors that future sessions need to know. Entries are chronological, most recent first.

**Entry format:**

```markdown
### YYYY-MM-DD: {Discovery Title}

{What was learned and why it matters. Include enough detail that a future session can act on this without re-investigation.}
```

**Rules:**
- Keep entries factual and actionable. Not a journal — a reference.
- If a discovery invalidates a previous discovery, add a new entry; do not edit the old one.
- Tag entries with relevant file paths or component names so they are searchable.

**Example:**

```markdown
# Discoveries

### 2026-02-10: pycomm3 silently returns stale data on connection timeout

pycomm3 does not raise an exception when a PLC connection times out mid-read. It returns the last cached value. The `plc_client.py` wrapper must check `comm.connected` after every `read()` call and reconnect if false. This was the root cause of the "phantom steady-state" incident on 2026-02-09.
```

## Optional Sections

### session.md

Tracks the current work session's state. Unlike decisions and discoveries (which are permanent), session state is ephemeral and may be cleared between work sessions.

**Content:** Current task, open questions, blocked items, next steps. Free-form but should be scannable.

```markdown
# Current Session

**Task:** Migrating collector pipeline from sync to async
**Status:** In progress — writers converted, PLC client pending
**Blocked:** Need to test async pycomm3 behavior under connection loss
**Next:** Convert `plc_client.py`, then integration test
```

### roadmap.md

Project-specific priorities and planned work. Not a company roadmap — scoped to this project only.

```markdown
# Roadmap

## Current Priority
- [ ] Async pipeline migration
- [ ] Connection pool tuning

## Next
- [ ] Add Prometheus metrics endpoint
- [ ] Implement graceful shutdown
```

## Example

A minimal but complete context directory for a new project:

```markdown
<!-- .claude/context/decisions.md -->
# Architecture Decisions

(No decisions recorded yet.)
```

```markdown
<!-- .claude/context/discoveries.md -->
# Discoveries

(No discoveries recorded yet.)
```

## Validation

A context directory is valid when:

1. It lives at `.claude/context/` inside the project root
2. `decisions.md` and `discoveries.md` both exist
3. All decision entries follow the Context/Decision/Consequences format
4. All discovery entries are timestamped with `### YYYY-MM-DD:` headers
5. Entries are ordered most-recent-first
6. No entries have been deleted or edited after creation (append-only)
7. No credentials, secrets, or tokens appear anywhere in context files
