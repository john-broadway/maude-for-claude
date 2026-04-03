# Specialist Routing Rules

> **Version:** 4.0
> **Created:** 2026-01-27
> **Last Updated:** 2026-02-06 12:11 MST
> **Status:** MANDATORY
> **Purpose:** Ensure Claude uses specialists instead of answering directly

---

## The Rule: Invoke Specialists First

**If a specialist exists for a domain, INVOKE THEM before answering or acting.**

This is mandatory. Not optional. Not "when convenient."

---

## Routing Decision Tree

```
User asks question or requests action
                ↓
Is there an MCP tool for this?
  ├── YES → Use MCP tool (all connections are direct internal IPs)
  └── NO → Continue
                ↓
Is there a skill for this domain?
  ├── YES → Invoke skill via Skill tool
  └── NO → Continue
                ↓
Is there an agent for this type of work?
  ├── YES → Invoke agent via Task tool
  └── NO → Continue
                ↓
Answer directly (only if no specialist exists)
```

The control plane is on the production network. All connections are direct. No environment switching needed.

For domain-to-tool/skill/agent mappings, see `CLAUDE.md` routing tables.

---

## Anti-Patterns

| Anti-Pattern | Correct Approach |
|--------------|------------------|
| Answering brand/design/creative questions directly | Invoke `/design` skill or `creative` agent |
| `curl -sk https://192.0.2.10:8006/...` | `pve_cluster_status(site="site-a")` |
| `psql -h ... -c "SELECT..."` | `mcp__postgres__query(sql="SELECT...")` |
| Calling `collector_data_freshness()` directly | Invoke `/collector` skill |
| Calling `grafana_health()` directly | Invoke `/grafana` skill |
| Explaining ITAR from memory | Invoke `compliance-chief` agent |
| Answering "What VMs are running?" | Use MCP or invoke `/proxmox` |
| Giving HR advice directly | Invoke `/hr` skill |
| Moving UNAS files without context | Use `migration-orchestrator` agent |

---

## When to Skip Routing

You may answer directly (without specialist) when:

1. **Meta questions** — "What agents do I have?" (answer from CLAUDE.md)
2. **General programming** — Coding questions not specific to Maude domains
3. **Explicit user override** — User says "don't use the agent, just tell me"
4. **Quick factual lookup** — Simple info already in CLAUDE.md

You MUST use specialists when:
1. **Domain-specific operations** — Anything in the routing table
2. **Infrastructure changes** — VM, container, network, storage operations
3. **Compliance questions** — ITAR, ISO, legal, HR implications
4. **File governance** — UNAS moves, naming, structure changes
5. **Industrial systems** — PLC, SCADA, HMI work

---

## Verification Checklist

Before answering a domain question, ask yourself:

- [ ] Is there an MCP tool for this? (Check `~/.claude/reference/mcp-servers.md`)
- [ ] Is there a skill for this domain?
- [ ] Is there an agent for this work?
- [ ] Did I invoke the specialist before answering?
- [ ] Am I using MCP instead of bash/curl?

---

## Related

- MCP Server Reference: `~/.claude/reference/mcp-servers.md`
- Maude Room Interaction: `~/.claude/reference/maude-interaction.md`
- Agents: `~/.claude/agents/` (auto-discovered)
- Skills: `~/.claude/skills/` (auto-discovered)
