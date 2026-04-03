---
title: Project Structure Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Project Structure Standard

## Purpose

Standardized directory layout so any developer can navigate any Maude project without
guessing where things live. Every repository follows the same skeleton, and
project-specific additions are layered on top predictably.

## Rules

### Required Files

Every Maude repository MUST contain:

| File | Purpose |
|------|---------|
| `.claude/CLAUDE.md` | Project identity, architecture, and conventions |
| `.gitignore` | Baseline ignore rules (see below) |
| `pyproject.toml` | Package metadata, dependencies, tool config (Python projects) |

### Required Directories (Python Projects)

| Directory | Purpose |
|-----------|---------|
| `src/{package_name}/` | Application source code using src-layout |

The package name MUST use `snake_case` matching the project (e.g., project `collector` uses `src/collector/`).

### Recommended Directories

| Directory | When to include |
|-----------|-----------------|
| `tests/` | Always, unless the project is pure configuration |
| `docs/` | When the project has architecture docs, ADRs, or runbooks |
| `scripts/` | Deployment, migration, or utility scripts |

### Project Configuration Directories

Projects SHOULD include:

| Directory | Purpose |
|-----------|---------|
| `.claude/rules/` | Behavioral rules loaded automatically |
| `.claude/agents/` | Agent definitions for multi-agent workflows |
| `.claude/context/` | Reference material loaded on demand |
| `.claude/skills/` | Reusable skill definitions |

### Sovereignty Scaffold

Every Maude project carries its identity in platform-namespaced dot-directories. Each platform owns its namespace — no platform writes into another's directory.

| Directory | Owner | Purpose |
|-----------|-------|---------|
| `.git/` | Git | Version control state |
| `.claude/` | Claude Code | Agent config, rules, skills, context |
| `.maude/` | Maude | Room identity, domain knowledge, runtime config, memory |

This pattern applies at every level: organization, subsidiary, department, service, project. An entity is sovereign when it carries its own metadata in a predictable location.

### The `.maude/` Directory

Projects that operate as a Maude Room MUST include a `.maude/` directory. This is Maude's sovereign namespace — everything the Room needs to know about itself lives here.

| Path | Purpose |
|------|---------|
| `.maude/identity.md` | Room identity — name, purpose, capabilities, owner |
| `.maude/memory/` | Learned memory organized by category (sessions, incidents, decisions) |
| `.maude/skills/` | Domain skill definitions consumed by the Room agent |
| `.maude/maude.env` | Runtime environment variables for the Maude service |

**Optional contents:**

| Path | When to include |
|------|-----------------|
| `.maude/knowledge/` | Static domain knowledge (specs, reference material, chemistry) |
| `.maude/prompts/` | Prompt templates for Room-specific interactions |

The `.maude/` directory is version-controlled. `maude.env` MUST NOT contain secrets — credentials are injected at runtime via the credential governance rules in the Constitution.

### Triad Alignment

Skills, agents, and knowledge share domain identity. When a Room has a skill for a domain, it SHOULD have corresponding knowledge and agent capability for that domain.

| Facet | Location | Purpose |
|-------|----------|---------|
| Skill | `.claude/skills/` | Routing — how to invoke the capability |
| Agent | `.claude/agents/` | Autonomy — specialist behavior for the domain |
| Knowledge | `.maude/knowledge/` | Memory — domain reference material the agent draws on |

A skill without knowledge is a routing stub. Knowledge without a skill is invisible. The triad is the complete unit of domain capability.

### Naming Conventions

- Directories and repository names: `kebab-case` (e.g., `example-hmi`, `alert-display`).
- Python packages: `snake_case` (e.g., `example_hmi`, `alert_display`).
- MUST NOT mix conventions within a project.

### Git Conventions

- Remote: `git@git.example.com:Maude/{repo}.git`
- Default branch: `main`.
- Working tree MUST be clean before ending a development session.
- MUST NOT commit directly to `main` for multi-developer projects; use feature branches and PRs.

### .gitignore Baseline

Every repository MUST include at minimum:

```gitignore
__pycache__/
*.pyc
.venv/
venv/
*.egg-info/
.env
*.log
.pytest_cache/
.mypy_cache/
.coverage
htmlcov/
dist/
build/
```

Additional entries MAY be added for project-specific needs.

### Maude Room Projects

Projects that run as a Maude Room (AI agent service) MUST additionally include:

| Path | Purpose |
|------|---------|
| `config.yaml` | Room configuration (identity, MCPs, schedules) |
| `.maude/` | Room sovereignty namespace (see The `.maude/` Directory above) |
| `deploy/` | Systemd units, deploy scripts, nginx configs (excluding `maude.env`) |

### Version Headers

- `CLAUDE.md` and `README.md` MUST include the authorship and version header per the Maude authorship standard.
- Source files MUST include headers when created or modified per the authorship standard.

## Examples

### Standard Python Project

```
collector/
  .claude/CLAUDE.md
  src/collector/
    __init__.py
    config.py
    models.py
    service.py
  tests/test_service.py
  scripts/deploy.sh
  docs/architecture.md
  pyproject.toml
  .gitignore
```

### Maude Room Project

```
lab-service/
  .claude/
    CLAUDE.md
    rules/lab-safety.md
    skills/bath-analysis/SKILL.md
    agents/lab-specialist.md
  .maude/
    identity.md
    maude.env
    memory/
      sessions.md
      incidents.md
    knowledge/
      domain-knowledge.md
      spc-methods.md
  src/lab_service/
    __init__.py
    room.py
    tools.py
  tests/test_tools.py
  deploy/
    lab-service.service
    deploy.sh
  config.yaml
  pyproject.toml
  .gitignore
```

Note the separation: `.claude/` holds Claude Code configuration (skills route to capabilities, agents define specialist behavior, rules enforce constraints). `.maude/` holds Maude runtime state (identity, environment, memory, domain knowledge). Neither platform writes into the other's namespace.

## Enforcement

- **CI check:** A project structure linter validates required files and directories exist before merging to `main`.
- **Session-end verification:** All contributors MUST confirm clean working tree and correct structure before ending a session.
- **New project template:** `maude/template/` provides a scaffolded skeleton that satisfies this standard out of the box.
