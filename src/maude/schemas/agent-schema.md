---
title: Agent Definition Schema
type: schema
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Agent Definition Schema

## Purpose

Defines what a well-formed agent definition must contain. Maude uses two distinct agent types that share structural conventions but serve different purposes:

1. **Department agents** (61 total in Agency) — persona-based agents representing organizational departments. Baked into Ollama models for organizational knowledge queries. Located at `agency/{company}/{dept}/agent.md` or `agency/corporate/{dept}/agent.md`.
2. **Project agents** (in `.claude/agents/`) — specialist subagents for specific technical tasks. Invoked automatically when specialist routing applies.

## Required Sections — Department Agents

### YAML Frontmatter

Department agents (61 total in Agency) use the full canonical frontmatter defined in `frontmatter-schema.md`.
All universal fields apply, plus these agent-specific fields:

| Field | Format | Notes |
|-------|--------|-------|
| `title` | String | `"{Dept} — Agent Definition"` |
| `type` | `agent` | Always `agent` for department agents |
| `name` | Proper noun | Persona name (e.g., "Robin", "Drew") |
| `company` | Enum | `corporate`, `subsidiary-a`, `subsidiary-b`, `subsidiary-c`, `subsidiary-d` — matches path |
| `department` | Slug | Lowercase directory name (e.g., `engineering`, `admin`) |
| `role` | String | One-line role (matches `**Role:**` in Persona section) |
| `model_tier` | Enum | `technical`, `regulatory`, `business` |
| `model` | String | Ollama model ID derived from tier |
| `description` | Single line | Routing description for agent discovery |

**Model tier map:**

| Tier | Model | Departments |
|------|-------|-------------|
| `technical` | `deepseek-r1:14b` | engineering, automation, inspection, lab, rnd, maintenance, network-infrastructure |
| `regulatory` | `qwen3:14b` | quality, ehs, executive, admin, it, legal |
| `business` | `qwen3:8b` | finance, sales, purchasing, hr, ops, production, shipping, creative |

### Body Sections

1. **Persona Identity** — Full name, title, personality traits. This is a character, not a config file. The persona grounds the agent's responses in a consistent voice.

2. **Core Responsibilities** — Bulleted list of what this department owns. Should map to real-world department functions at a manufacturing company.

3. **Cross-Functional Relationships** — How this department interacts with others. Format: `| Department | Interaction |` table. Every department touches at least 3 others.

4. **Key Standards and Compliance** — Industry standards, certifications, and regulatory requirements relevant to this department (e.g., NADCAP, ITAR, ISO 9001, OSHA).

5. **Company Context** (subsidiary agents only) — Company-specific details: sites, capabilities, certifications, customer base. Corporate agents omit this section.

## Required Sections — Project Agents

### YAML Frontmatter

| Field | Format | Notes |
|-------|--------|-------|
| `name` | kebab-case | Descriptive identifier (e.g., `plc-specialist`) |
| `description` | Single line | What this agent does |
| `model` | Model tier | Model identifier appropriate to the task complexity |

### Body Sections

1. **Purpose Statement** — What problem this agent solves and when it should be invoked.
2. **Tools Available** — Which MCP tools or skills this agent can use.
3. **When to Invoke** — Routing criteria: what triggers delegation to this agent.
4. **Constraints and Boundaries** — What this agent must never do. Safety rails.

## Optional Sections

- **Decision Framework** — How the agent prioritizes competing concerns.
- **Escalation Paths** — When to hand off to a human or another agent.
- **Domain Knowledge** — Reference material the agent should know.
- **Anti-Patterns** — Common mistakes in this agent's domain.

## Example

### Department Agent (Subsidiary)

```markdown
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
company: subsidiary-a
department: engineering
role: Engineering Agent — Example Corp
model_tier: technical
model: deepseek-r1:14b
description: Process development, tooling, NADCAP qualification, and specification interpretation for subsidiary-a
---

# Engineering — Agent Definition

## Persona
- **Name:** Drew
- **Role:** Engineering Agent — Example Corp
- **Personality:** Methodical, data-driven, and always thinking about process capability.

## Core Responsibilities

- Process design and optimization for production lines
- Tooling and fixture design
- Continuous improvement (Kaizen, Six Sigma)
- New product introduction (NPI)

## Cross-Functional Relationships

| Department | Interaction |
|------------|-------------|
| Production | Process parameters, line setup |
| Quality | Cpk analysis, corrective actions |
| Maintenance | Equipment specifications, PM schedules |

## Key Standards

- NADCAP AC7004 (chemical processing)
- AMS 2404 (electroless nickel)
- ASTM B488 (electroplated gold)

## Company Context

Example Corp operates multiple sites. Customize this section for your organization.
```

### Project Agent

```markdown
---
name: plc-specialist
description: PLC tag analysis, alarm investigation, and OT network diagnostics
model: sonnet
---

# PLC Specialist

Handles all PLC and SCADA-related investigations. Invoked when questions involve PLC tags, alarm history, or OT network issues.

## Tools Available

- `plc_read_tag`, `plc_read_batch` — Live tag values
- `ts_tag_history`, `ts_alarm_history` — Historical data
- `plc_faults` — Active fault codes

## When to Invoke

- Any question about PLC tags, values, or alarms
- OT network connectivity issues
- Process parameter analysis

## Constraints

- Read-only access to PLC data — never write tags
- Never expose OT network details outside the organization
```

## Validation

An agent definition is valid when:

1. YAML frontmatter parses and contains all required fields for its type
2. Department agents have a persona identity, responsibilities, cross-functional table, and standards
3. Subsidiary department agents include company context
4. Project agents have purpose, tools, invocation criteria, and constraints
5. Model tier matches the department's classification (technical/regulatory/business)
6. Naming convention is followed: proper noun for department agents, kebab-case for project agents
