---
title: Knowledge Directory Schema
type: schema
version: 1.2.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Knowledge Directory Schema

## Purpose

Defines how the `.maude/` directory must be structured for Maude services. This
is Maude's sovereign namespace — a service's identity, operational memory,
learned patterns from past incidents, and skill guides for autonomous action.
A service without well-structured knowledge is a service that escalates everything.

The `.maude/` directory is the canonical location per the project structure
standard's sovereignty scaffold convention. Each platform owns its dot-directory:
`.git/` for Git, `.claude/` for Claude Code, `.maude/` for Maude.

## Required Structure

```
.maude/
├── identity.md          # What this service is, what it manages
├── maude.env           # Runtime environment variables (no secrets)
├── memory/
│   ├── incidents.md     # Past incidents and resolutions
│   ├── patterns.md      # Learned operational patterns
│   └── preferences.md   # Operator preferences and local conventions
└── skills/
    ├── health.md        # How to assess service health
    └── triage.md        # How to diagnose issues
```

All files are markdown. All filenames are lowercase kebab-case.

## Required Sections

### identity.md

The service's self-description. Loaded first, sets the context for everything
else.

| Section | Content |
|---------|---------|
| Service Name and Purpose | What this service manages, one paragraph |
| Infrastructure Context | Where it runs, its dependencies |
| Capabilities Summary | What operations this service can perform |
| Escalation Paths | When to escalate vs. handle autonomously, and to whom |
| Operational Boundaries | What this service must never do |

### memory/incidents.md

Past incidents encountered and how they were resolved. Entries are timestamped,
most recent first.

```markdown
### 2026-02-10: PostgreSQL connection pool exhaustion
**Symptoms:** Slow queries, connection refused errors on port 5432.
**Root Cause:** Runaway batch job holding 45 connections for 3+ hours.
**Resolution:** Terminated idle connections, added connection timeout to batch config.
**Learning:** Check connection pool status first when queries slow down.
```

### memory/patterns.md

Recurring operational patterns learned over time. Not incidents —
generalizations extracted from multiple incidents or observations.

```markdown
### Backup failures correlate with high disk I/O
When NFS throughput drops below 50 MB/s, backup jobs timeout. Check storage
status before investigating backup errors.
```

### memory/preferences.md

Operator preferences and local conventions that differ from defaults.

```markdown
### Alert formatting
John prefers bullet-point summaries over paragraphs. Lead with the metric
value, then context.
```

### skills/health.md

Step-by-step procedure for assessing the service's health. Followed
autonomously during scheduled checks.

Must include:
- Ordered checklist of health indicators to check
- Which tools to call for each indicator
- Thresholds for healthy/warning/critical
- What to do at each severity level

### skills/triage.md

Decision tree for diagnosing issues when an alert fires or an anomaly is
detected.

Must include:
- Entry point: what triggered the triage
- Branching logic: if X then check Y
- Resolution actions for common root causes
- Escalation criteria: when to give up and call a human

## Optional Structure

Additional files may be added under `memory/`, `skills/`, or `knowledge/` as the
service learns:

```
.maude/
├── knowledge/
│   ├── domain-knowledge.md   # Static domain reference material
│   └── spc-methods.md         # Technical procedures
├── memory/
│   └── maintenance.md         # Maintenance windows, scheduled downtime
├── prompts/
│   └── triage-template.md     # Prompt templates for Room interactions
└── skills/
    ├── backup.md              # Backup verification procedures
    ├── scaling.md             # Capacity planning guides
    └── recovery.md            # Disaster recovery procedures
```

The `knowledge/` subdirectory holds static domain reference material (specs,
chemistry, procedures). The `memory/` subdirectory holds learned operational
state (incidents, patterns, preferences). The distinction: knowledge is authored,
memory is accumulated.

## Example

A minimal but complete `identity.md`:

```markdown
# PostgreSQL Service

Manages the PostgreSQL + TimescaleDB instance serving the data platform.

## Infrastructure

- **Host:** LXC 201
- **Dependencies:** Backup service, metrics collection, dashboards

## Capabilities

| Function | Operations |
|----------|------------|
| Queries | Query stats, connection pool status |
| Health | Data freshness, vacuum status |
| Backup | Backup status, chunk health |

## Escalation

- **Self-heal:** Terminate idle connections, trigger vacuum
- **Escalate:** Replication lag > 5 min, backup failure > 24h, disk > 90%

## Boundaries

- Never DROP databases or tables without operator confirmation
- Never modify access control config — that is a provisioning task
```

## Migration

Existing projects using `knowledge/` at the project root SHOULD migrate to
`.maude/` in a future commit. The migration is mechanical:

1. `knowledge/identity.md` → `.maude/identity.md`
2. `knowledge/memory/*` → `.maude/memory/*`
3. `knowledge/skills/*` → `.maude/skills/*`
4. `deploy/maude.env` → `.maude/maude.env`
5. Remove empty `knowledge/` and update `deploy/` if now empty

Consumer code (Maude library) will be updated to discover `.maude/` first,
falling back to `knowledge/` during the transition period.

## Validation

A `.maude/` directory is valid when:

1. `identity.md` exists and contains all five required sections
2. `memory/` contains `incidents.md`, `patterns.md`, and `preferences.md`
3. `skills/` contains at minimum `health.md` and `triage.md`
4. `maude.env` exists and contains no secrets (passwords, tokens, keys)
5. All memory entries are timestamped and ordered most-recent-first
6. All skill files contain actionable procedures, not just descriptions
7. No hardcoded credentials appear anywhere in the `.maude/` directory
