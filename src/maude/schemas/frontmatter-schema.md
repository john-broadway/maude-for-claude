---
title: YAML Frontmatter Schema
type: schema
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# YAML Frontmatter Schema

## Purpose

Defines the canonical YAML frontmatter format for all Agency artifacts. Every
markdown file in the Agency repository carries structured metadata in a fenced
YAML block at the top of the file. This metadata is machine-extractable,
version-tracked, and auditable — fulfilling the Constitution's requirement that
every artifact has an owner, a version, and a history.

## Required Structure — Universal Fields

All Agency artifacts MUST begin with a YAML frontmatter block containing these
fields:

| Field | Type | Format | Notes |
|-------|------|--------|-------|
| `title` | string | Human-readable title | Matches the `# Title` heading in the body |
| `type` | enum | See type values below | Classifies the artifact |
| `version` | string | SemVer `X.Y.Z` | Per authorship-headers standard |
| `authors` | list | `"Name <email>"` entries | Non-empty; all contributors |
| `updated` | date | `YYYY-MM-DD` (ISO 8601) | Last modification date |
| `status` | enum | Per-type values below | Current lifecycle status |

### Type Values

```
agent | standard | schema | constitution | profile | capabilities | facilities
```

### Status Values by Type

| Type | Allowed Values |
|------|----------------|
| `constitution` | `SUPREME LAW` |
| `standard`, `schema` | `MANDATORY`, `RECOMMENDED`, `ADVISORY` |
| `agent`, `profile`, `capabilities`, `facilities` | `ACTIVE`, `DEPRECATED` |

## Required Structure — Agent Fields

Artifacts with `type: agent` MUST include these additional fields:

| Field | Type | Format | Notes |
|-------|------|--------|-------|
| `name` | string | Proper noun | Persona name (e.g., "Robin", "Drew") |
| `company` | enum | `corporate`, `hp`, `aim`, `sbm`, `do` | Derived from filesystem path |
| `department` | string | Lowercase slug | Matches directory name |
| `role` | string | Single line | Matches `**Role:**` value in Persona section |
| `model_tier` | enum | `technical`, `regulatory`, `business` | Determines model selection |
| `model` | string | Ollama model ID | Derived from tier |
| `description` | string | Single line | Routing description for agent discovery |

### Model Tier Map

| Tier | Model | Departments |
|------|-------|-------------|
| `technical` | `deepseek-r1:14b` | engineering, automation, inspection, lab, rnd, maintenance, network-infrastructure |
| `regulatory` | `qwen3:14b` | quality, ehs, executive, admin, it, legal |
| `business` | `qwen3:8b` | finance, sales, purchasing, hr, ops, production, shipping, creative |

## Required Structure — Profile/Capabilities/Facilities Fields

Artifacts with `type: profile`, `type: capabilities`, or `type: facilities`
MUST include:

| Field | Type | Format | Notes |
|-------|------|--------|-------|
| `company` | enum | `hp`, `aim`, `sbm`, `do` | Derived from filesystem path |

Artifacts with `type: profile` SHOULD include:

| Field | Type | Format | Notes |
|-------|------|--------|-------|
| `company_name` | string | Full legal name | e.g., "Acme Manufacturing Co." |

## Example

### Agent (Subsidiary)

```yaml
---
title: Engineering — Agent Definition
type: agent
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: ACTIVE
name: Drew
company: hp
department: engineering
role: Engineering Agent — Example Corp
model_tier: technical
model: deepseek-r1:14b
description: Process engineering, rack design, NADCAP qualification, and specification interpretation for HP surface finishing
---

# Engineering — Agent Definition

## Persona
- **Name:** Drew
- **Role:** Engineering Agent — Example Corp
...
```

### Standard

```yaml
---
title: Python Style Standard
type: standard
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Python Style Standard

## Purpose
...
```

### Subsidiary Profile

```yaml
---
title: Acme Manufacturing
type: profile
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: ACTIVE
company: hp
company_name: Acme Manufacturing Co.
---

# Acme Manufacturing

## Overview
...
```

## Body Content Rules

- **Agent files:** The `## Persona` section with `**Name:**`, `**Role:**`, etc.
  is preserved unchanged. Three consumer applications regex-parse these fields.
  Frontmatter adds structured metadata; the body preserves backward compatibility.

- **Standards, schemas, constitution:** The blockquote header (`> **Version:**`,
  `> **Authors:**`, etc.) is REMOVED after migration. The `# Title` heading and
  all `## ` sections remain.

- **Profiles, capabilities, facilities:** Body is unchanged. Frontmatter is
  prepended.

## Validation

An artifact's frontmatter is valid when:

1. The file begins with `---` on its own line
2. The YAML block is closed with `---` on its own line
3. All universal fields are present and correctly typed
4. The `type` value is one of the allowed enum values
5. The `status` value is valid for the artifact's type
6. The `version` matches SemVer format (`X.Y.Z`)
7. The `updated` date is valid ISO 8601 (`YYYY-MM-DD`)
8. The `authors` list is non-empty with entries in `"Name <email>"` format
9. Type-specific required fields are present (agent fields, profile fields)
10. For agents: `model` matches the canonical tier map for the given `model_tier`
11. For agents: `company` and `department` match the filesystem path
