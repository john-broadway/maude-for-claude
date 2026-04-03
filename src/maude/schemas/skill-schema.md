---
title: Skill Definition Schema
type: schema
version: 1.2.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-06
status: MANDATORY
---

# Skill Definition Schema

## Purpose

Defines what a well-formed `SKILL.md` file must contain. Skills are the primary
interface between operators and service capabilities — invoked by name when a
specific domain action is needed. Maude supports 97 skills spanning
operational domains (example-scada, grafana, postgresql) and advisory domains
(production, quality, engineering). A skill that fails this schema is a skill
that fails to route correctly.

## Required Sections

### YAML Frontmatter

Every SKILL.md must begin with a fenced YAML block containing:

| Field | Format | Notes |
|-------|--------|-------|
| `domain` | kebab-case | Must match the filename stem (e.g., `health.md` → `domain: health`). `name` is accepted as a legacy alias but `domain` is canonical. |
| `description` | Single line, starts with a verb or role descriptor | This is the routing line — the system uses it to decide whether to invoke the skill. Make it maximally informative. |

The `description` field is critical. It appears in the skill list during
routing. A vague description means the skill never gets invoked. Good:
`"Query and manage PostgreSQL databases, run health checks, analyze slow queries"`.
Bad: `"PostgreSQL stuff"`.

### Body Sections

1. **Purpose / Overview** — One to three paragraphs explaining what this skill
   does, when to use it, and what domain it covers.

2. **Key Principles or Constraints** — Bulleted list of rules the skill must
   follow. Safety boundaries, tool-first patterns, things to never do. Minimum
   3 items.

3. **Process Flow or Checklist** (required for operational skills, optional for
   advisory) — Numbered steps or decision tree that the skill follows when
   invoked. This is the skill's playbook.

## Optional Sections

- **Tool Routing Table** — `| Task | Tool | Never |` table mapping operations
  to specific tools and listing forbidden alternatives.
- **Anti-Patterns** — Common mistakes to avoid when using this skill.
- **Related Skills** — Other skills that complement or overlap with this one.
- **Escalation** — When this skill should hand off to a human or another skill.

## Example

```markdown
---
domain: postgresql
description: Query and manage PostgreSQL databases, run health checks, analyze slow queries, manage backups
---

# PostgreSQL Skill

Manages all PostgreSQL operations across the your infrastructure.

## Key Principles

- Always use sanctioned database access tools — never shell out to `psql`
- Never mix data between databases
- Backup before any schema change
- Use transactions for multi-statement writes

## Process Flow

1. Identify which database the request targets
2. For reads: execute query via sanctioned tool, format results
3. For writes: wrap in transaction, confirm with operator if destructive
4. For health checks: check connection pool, vacuum status, replication lag
```

## Validation

A SKILL.md is valid when:

1. YAML frontmatter parses without error and contains both `domain` and `description`
2. The `domain` field matches the filename stem (kebab-case, e.g., `health.md` → `domain: health`)
3. The `description` starts with a verb or role descriptor and is a single line
4. The body contains at minimum: purpose paragraph, key principles list, and (for operational skills) a process flow
5. No hardcoded credentials or secrets that should come from config
