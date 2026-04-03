---
title: MCP-First Access Standard
type: standard
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-15
status: MANDATORY
---

# MCP-First Access Standard

## Purpose

Codifies the "MCP First" operational principle as a Federal Standard under Art. II Sec. 3 (sanctioned interfaces). Previously interpolated into the constitutional digest without textual basis in Article II — corrected by constitutional convention on 2026-03-15.

## Rules

All interaction with Maude infrastructure services MUST use sanctioned MCP tools
or skill commands. Direct access via curl, wget, ssh, psql, or other CLI tools
to Maude network endpoints is forbidden except for explicitly exempted operations.

## Blocked Patterns

| Pattern | Alternative |
|---------|------------|
| `curl` / `wget` to `10.(10\|20\|30\|40\|50).0.x` | Use the appropriate MCP server |
| `ssh` to Maude subnets | Use MCP tools or skill commands |
| `psql` to `db.example.com` | Use `mcp__postgres__query` |
| `curl` to `:8006` / `:8007` | Use `pve_*` / `pbs_*` MCP tools |
| `curl` / `wget` to `192.168.x.x` (PLC VLAN) | Use `device_read MCP tools` MCP tools |

## Exemptions

| Pattern | Reason |
|---------|--------|
| `ping`, `traceroute`, `dig`, `nslookup` | Diagnostic, read-only |
| `git` commands (push/pull via SSH) | Gitea operations are legitimate |
| `localhost` / `127.0.0.1` | Local operations |
| `scp` / `rsync` in `deploy.sh` scripts | Deployment is a sanctioned operation |

## Examples

**Correct:**
- `mcp__postgres__query` with `SELECT * FROM plc_tags` → uses sanctioned tool
- `/postgresql health` → uses skill command
- `ping db.example.com` → diagnostic exemption, allowed

**Incorrect:**
- `curl db.example.com:5432` → blocked, use `mcp__postgres__query`
- `ssh room.example.com` → blocked, use MCP tools for Room interaction
- `psql -h db.example.com -U user mydb` → blocked, use `mcp__postgres__query`

## Enforcement

Mechanically enforced by `~/.claude/hooks/mcp-first-guard.sh` (PreToolUse on Bash). The hook uses subnet-based matching to catch the entire Maude network range rather than enumerating individual IPs.

Denial messages include routing guidance to the correct MCP tool.

## Constitutional Basis

Art. II Sec. 3: "Room-to-room interaction passes through sanctioned interfaces. No Room directly accesses another Room's internal state."

This standard specifies that MCP servers ARE the sanctioned interfaces for Claude Code interaction with Maude infrastructure.
