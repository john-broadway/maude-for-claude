---
title: CLAUDE.md Schema
type: schema
version: 1.2.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-04
status: MANDATORY
---

# CLAUDE.md Schema

## Purpose

Defines what every project's `.claude/CLAUDE.md` must contain. CLAUDE.md is the
primary project documentation file — it communicates project identity,
architecture, conventions, and routing to any contributor landing in the repo.
Every project under `~/projects/` must have one. A project without a CLAUDE.md
is a project no one can reason about correctly.

## Required Sections

### Version Header

Every CLAUDE.md starts with a version block. Blockquote is the standard format (used by 29/31 project files); YAML frontmatter is also accepted.

**Standard (blockquote):**

```markdown
> **Version:** 1.2
> **Updated:** 2026-02-14
```

**Also accepted (YAML frontmatter):**

```markdown
---
title: "Collector"
type: claude-md
version: 1.2.0
updated: 2026-02-14
---
```

```markdown
> **Version:** 1.2
> **Updated:** 2026-02-14
```

Version tracks meaningful changes to the CLAUDE.md itself (not the project). Bump on every edit.

### Project Identity

One sentence describing what this project is. Should answer: "If I land in this repo cold, what am I looking at?"

```markdown
Assay is a lab MES replacing TrueChem — chemical management, bath analysis, SPC for manufacturing operations.
```

### Architecture Overview

Key components and how they relate. Can be a paragraph, a list, or a diagram — but must convey the structural shape of the project. For services: what runs where. For libraries: what the modules are. For apps: what the layers are.

### Key Files Table

A table mapping the most important files to their purpose. This is the "start here" guide.

```markdown
| File | Purpose |
|------|---------|
| `src/collector/pipeline.py` | Main data collection pipeline |
| `config.yaml` | Runtime configuration |
| `scripts/deploy.sh` | Production deployment |
```

Minimum 3 entries. Maximum ~15. If you need more, the project needs better organization, not a longer table.

### Related Projects / Routing

What other projects in `~/projects/` this project connects to, and when to look there instead of here. This prevents solving problems in the wrong repo.

```markdown
## Related Projects

| Project | Relationship |
|---------|-------------|
| `maude` | Platform library — Room agent base classes |
| `infrastructure/proxmox` | Infrastructure — where this service runs |
| `collector` | Upstream data source for this service |
```

## Optional Sections

### Project-Specific Rules

Rules that extend (never contradict) the global rules in `~/.claude/CLAUDE.md`. Example: "All SQL migrations must use Alembic" or "Never import from `internal/` outside this package."

### Development Workflow

Build, test, and deploy commands. What any contributor needs to run.

```markdown
## Development

- **Build:** `python -m build`
- **Test:** `pytest tests/`
- **Deploy:** `./scripts/deploy.sh`
- **Lint:** `ruff check src/`
```

### Environment Setup

Dependencies, config files, required environment variables. Not credentials (those live in `~/.credentials/secrets.yaml`), but structural requirements.

### Troubleshooting Guide

Common failure modes and how to diagnose them. Especially valuable for services with complex runtime behavior.

## Example

A minimal but complete CLAUDE.md:

```markdown
> **Version:** 1.0
> **Updated:** 2026-02-14

# Collector

PLC data collection service running on CTID 1050. Reads tags from Allen-Bradley PLCs via pycomm3, buffers in Redis, writes to InfluxDB and PostgreSQL/TimescaleDB.

## Architecture

- `src/collector/pipeline.py` — Main collection loop (async)
- `src/collector/plc_client.py` — pycomm3 wrapper with retry logic
- `src/collector/writers/` — InfluxDB and PostgreSQL write backends
- `config.yaml` — Tag lists, polling intervals, connection strings

## Key Files

| File | Purpose |
|------|---------|
| `src/collector/pipeline.py` | Main async collection pipeline |
| `src/collector/plc_client.py` | PLC communication layer |
| `config.yaml` | Runtime configuration |
| `scripts/deploy.sh` | Deployment to CTID 1050 |

## Related Projects

| Project | Relationship |
|---------|-------------|
| `infrastructure/proxmox` | Host infrastructure (PVE + PBS) |
| `infrastructure/maude` | Room agent platform |
| `infrastructure/influxdb` | Write target for time-series data |
| `infrastructure/postgresql` | Write target for relational data |

## Development

- **Test:** `pytest tests/ -v`
- **Deploy:** `./scripts/deploy.sh`
- **Config:** Copy `config.example.yaml` to `config.yaml`, fill in connection strings
```

## Validation

A CLAUDE.md is valid when:

1. It lives at `.claude/CLAUDE.md` (capital letters, inside `.claude/` directory)
2. Version header is present with version number and date
3. Project identity is a single clear sentence
4. Architecture overview conveys the structural shape of the project
5. Key files table has at least 3 entries with `| File | Purpose |` format
6. Related projects section names at least one connected project
7. No credentials, secrets, or tokens appear anywhere in the file
