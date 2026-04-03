---
type: skill
domain: health
description: Diagnose service health using multi-layer checks across systemd, process state, resources, and endpoint connectivity
version: 1.1
---

# Health Diagnostic Flow

Diagnose service health using multi-layer checks across systemd, process state, resources, and endpoint connectivity


## Key Principles

- **Use MCP tools (`service_health`, `service_status`) before SSH fallback** -- MCP tools are the sanctioned interface; SSH is a last resort
- **Never restart as a first response** -- diagnose the root cause first; check `service_errors` for crash patterns and distinguish between local and upstream failures
- **Upstream dependency failures are not your problem to fix** -- if the issue is in PostgreSQL, Qdrant, or vLLM, log the finding and escalate; restarting this service will not help
- **Crash loops (>3/hr) mean stop restarting and investigate** -- the health loop's restart limit exists for a reason; persistent failures need root cause analysis, not more restarts
- **Track trends, not just current values** -- connections climbing, disk filling, or memory growing are early warnings; act on the trend before it becomes a critical failure

## Scheduled Checks (slim prompt, 512 token limit)

On `scheduled_check` triggers you run with a minimal system prompt and must
call at least one tool. Keep it brief:

1. Call `service_health` — check composite status
2. If healthy → output summary + `<outcome>no_action</outcome>`
3. If unhealthy → call additional tools, then summarize

## Process Flow

1. Check service status via `service_status` or `service_health`
2. If unhealthy, check `service_errors` for recent error messages
3. Check `service_logs` for patterns leading up to the failure
4. If service is down, attempt restart via `service_restart` (guarded)
5. If restart fails, escalate — check dependencies and disk/memory

## Escalation Checks (full prompt, 4096 token limit)

On `health_loop_escalation` triggers you get the full identity, skills, and
memory context. Use the deeper flow below.

### Quick Check
1. `service_status` — is the service running?
2. `service_health` — composite health (service + memory + disk + errors)
3. `{{PROJECT}}_health` — domain-specific health

### If Unhealthy
1. `service_errors` — check recent errors
2. `service_logs` — look for patterns
3. Determine: is this a service issue or upstream issue?

### Decision
- Service issue + recoverable → `service_restart` with reason
- Upstream issue → do NOT restart, log and escalate
- Unknown → gather more data, escalate if still unclear
