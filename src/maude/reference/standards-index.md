# Project & Document Standards

> **Version:** 3.0
> **Created:** 2026-01-27
> **Last Updated:** 2026-03-29
> **Status:** MANDATORY

Consolidated from `standards.md` + `document-control.md`.

---

## Repository Checklist

Every repo in `~/projects/` MUST have:

| Item | Requirement | Verify |
|------|-------------|--------|
| `README.md` | Doc-control header (Version, Created, Last Updated, Status) | `head -6 README.md` |
| `.claude/CLAUDE.md` | `> **Version:** X.Y` + `> **Last Updated:** YYYY-MM-DD HH:MM TZ` | `head -5 .claude/CLAUDE.md` |
| `.gitignore` | Python caches: `.pytest_cache/`, `.mypy_cache/`, `.pyright/`, `.coverage`, `htmlcov/`, `dist/`, `build/` | `grep pytest_cache .gitignore` |
| Git remote | Pushed to Gitea (`git.example.com/YourOrg/<repo>`) | `git remote -v` |
| Clean working tree | No uncommitted changes before ending a session | `git status` |

---

## Required Headers by File Type

### Project README.md

```markdown
# Project Title

> **Version:** X.Y
> **Created:** YYYY-MM-DD
> **Last Updated:** YYYY-MM-DD HH:MM TZ
> **Status:** Active | Draft | Deprecated
```

### Project CLAUDE.md

```markdown
# CLAUDE.md - Project Name

> **Version:** X.Y
> **Last Updated:** YYYY-MM-DD HH:MM TZ
```

### ~/.claude/ Markdown Files

```markdown
> **Version:** X.Y
> **Created:** YYYY-MM-DD
> **Last Updated:** YYYY-MM-DD HH:MM TZ
> **Status:** Draft | Active | Deprecated
```

### Agent Files (`~/.claude/agents/*.md`)

```markdown
---
name: agent-name
description: "..."
model: sonnet
version: 1.0
created: 2026-01-27
updated: 2026-01-27
---
```

### Skill Files (`~/.claude/skills/*/SKILL.md`)

```markdown
---
name: skill-name
description: "..."
version: 1.0
created: 2026-01-27
updated: 2026-01-27
---
```

### Hook Scripts (`~/.claude/hooks/*.sh`)

```bash
#!/bin/bash
# Hook: descriptive-name
# Version: 1.0
# Created: 2026-01-27
# Updated: 2026-01-27
# Purpose: Brief description
```

---

## Version Numbering

| Change Type | Version Bump | Example |
|-------------|--------------|---------|
| Breaking change, major rewrite | MAJOR | 1.0 → 2.0 |
| New feature, significant addition | MINOR | 1.0 → 1.1 |
| Bug fix, typo, minor tweak | MINOR | 1.1 → 1.2 |

---

## Update Protocol

When editing any Claude-managed file:

1. **Update the `Last Updated` timestamp** — always `YYYY-MM-DD HH:MM TZ`
2. **Increment version** if changes are significant
3. **Add revision history entry** for major changes (optional for minor)

**Never use date-only timestamps.** Always include hours, minutes, and timezone.

---

## Time Source

All timestamps MUST be sourced from the control plane's local system clock:

```bash
date +"%Y-%m-%d %H:%M %Z"
```

- **Timezone:** `America/Boise` (MST in winter, MDT in summer)
- **Never guess the time** — always run the `date` command
- **Format:** `YYYY-MM-DD HH:MM MST` or `YYYY-MM-DD HH:MM MDT`

---

## .gitignore Baseline

Every Python project must ignore at minimum:

```gitignore
__pycache__/
*.pyc
.venv/
venv/
*.egg-info/
.env
*.log
node_modules/
.DS_Store
*.swp
*.swo
.pytest_cache/
.mypy_cache/
.pyright/
.coverage
htmlcov/
dist/
build/
*.egg
```

---

## Files Requiring Version Control

### Always Version (MANDATORY)

| Location | Files |
|----------|-------|
| `~/.claude/CLAUDE.md` | Global config |
| `~/.claude/agents/*.md` | All agent definitions |
| `~/.claude/skills/*/SKILL.md` | All skill definitions |
| `~/.claude/rules/*.md` | All rule files |
| `~/projects/*/.claude/CLAUDE.md` | Project configs |
| `~/projects/*/README.md` | Project READMEs |

### Exempt (No Version Required)

| Location | Reason |
|----------|--------|
| `~/.claude/settings.json` | Auto-managed |
| `~/.claude/.mcp.json` | Auto-managed |
| Cache directories | Ephemeral |
| Log files | Timestamped by nature |

---

## Verification Script

```bash
for proj in infrastructure/maude infrastructure/postgresql infrastructure/grafana infrastructure/prometheus infrastructure/loki industrial/example-scada industrial/lab-service apps/erp-app; do
  grep -q "Version:" ~/projects/$proj/README.md 2>/dev/null && echo "OK  $proj README" || echo "FAIL $proj README"
  grep -q "Version:" ~/projects/$proj/.claude/CLAUDE.md 2>/dev/null && echo "OK  $proj CLAUDE" || echo "FAIL $proj CLAUDE"
  grep -q "pytest_cache" ~/projects/$proj/.gitignore 2>/dev/null && echo "OK  $proj gitignore" || echo "FAIL $proj gitignore"
done
```

---

## Federal Standards Registry

14 mandatory standards in `agency/standards/`:

| Standard | Version | Constitutional Basis |
|----------|---------|---------------------|
| authorship-headers.md | 1.1.0 | Art. III Sec. 2 |
| code-quality.md | 1.1.0 | Demoted from Art. VII (Amendment A2) |
| commit-messages.md | 1.0.0 | Art. III, Art. VIII |
| configuration.md | 1.1.0 | Art. V Sec. 4 |
| database-access.md | 1.1.0 | Art. VI Sec. 1-3 |
| dependency-management.md | 1.1.0 | Art. IV Sec. 1 |
| fab-pattern.md | 1.1.0 | Art. III Sec. 2, Art. IV Sec. 1 |
| logging.md | 1.1.0 | Art. III Sec. 1, Art. V Sec. 4 |
| mcp-first.md | 1.0.0 | Art. II Sec. 3 |
| port-convention.md | 1.1.0 | Art. II Sec. 3, Art. III Sec. 3 |
| project-structure.md | 1.1.0 | Art. II Sec. 1 |
| python-style.md | 1.0.0 | Code Quality Standard |
| testing.md | 1.1.0 | Art. III, Code Quality |
| ai-chat-persistence.md | 1.1.0 | Art. III Sec. 1, Art. VI Sec. 3 |

## Related

- Code quality standard: `agency/standards/code-quality.md`
- Report formatting: `~/.claude/reference/report-formatting.md`
- Specialist routing: `~/.claude/reference/specialist-routing.md`
