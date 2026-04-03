<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Governance

The governance engine enforces organizational rules through a layered system:
a Constitution of 11 articles, 6 Federal Standards, and 7 pre-built
enforcement hooks. Everything ships in `src/maude/governance/`.

---

## The Constitution

The Constitution is the supreme law for all rooms and agents. It ships as a
set of Markdown templates in `src/maude/governance/constitution/`. Rooms
copy the relevant articles into their `.claude/rules/` directory so Claude
Code can read and follow them.

### Hierarchy

Rules are applied in strict priority order:

1. **Constitution** — Supreme law. Non-negotiable. Covers governance, safety,
   data, credentials, and enforcement.
2. **Federal Standards** — Implementation conventions that apply to all rooms.
   Mandatory compliance.
3. **Project Rules** — Room-specific rules. Cannot contradict the Constitution
   or Federal Standards.
4. **Project Identity** — Room guidance and operational context. Informational,
   not binding.

A lower layer can extend but never override a higher layer.

### Articles

| Article | File | Summary |
|---------|------|---------|
| Preamble | `preamble.md` | Purpose and founding principles of the Maude framework |
| I — Governance | `article-i-governance.md` | Human authority is final; Executive has operational authority with hard limits; delegation never transfers accountability |
| II — Sovereignty | `article-ii-sovereignty.md` | Each room is sovereign in its domain; room-to-room interaction through sanctioned interfaces only; production and development are separate domains |
| III — Accountability | `article-iii-accountability.md` | Immutable audit trail; mandatory authorship on every artifact; traceability from current state to origin |
| IV — Safety | `article-iv-safety.md` | Irreversible actions require explicit consent; know the blast radius; files are preserved, never destroyed; read before edit |
| V — Credentials | `article-v-credentials.md` | No shared credentials across trust boundaries; credentials never in source code or logs; all usage must be auditable |
| VI — Data | `article-vi-data.md` | Each data store serves a single domain; backup before schema changes; multi-statement writes use explicit transactions |
| VII — Enforcement | `article-vii-enforcement.md` | Guards required for all risk-carrying operations; read broadly authorized, write requires explicit grants; guards cannot be bypassed |
| VIII — Amendments | `article-viii-amendments.md` | Changes require proposal, rationale, impact assessment, and Management ratification |
| Bill of Rights | `bill-of-rights.md` | 7 rights: Identity, Territory, Full Capability, Self-Governance, Due Process, Representation, Knowledge. Violations are halted and logged immediately |
| Digest | `digest.md` | Condensed summary of all articles — the version loaded into CLAUDE.md for quick reference |

---

## Federal Standards

Six standards ship in `src/maude/governance/standards/`. These are
implementation conventions that apply uniformly across all rooms.

| Standard | File | What It Covers |
|----------|------|----------------|
| Code Quality | `code-quality.md` | Minimum complexity, explicit over implicit, validate at boundaries, dead code removed |
| Testing | `testing.md` | Test structure, naming conventions, coverage requirements, test isolation |
| Logging | `logging.md` | Log levels, structured fields, what to log and what not to log |
| Commit Messages | `commit-messages.md` | Format, tense, scope, co-authorship attribution |
| Dependency Management | `dependency-management.md` | Version pinning, extras, security audit cadence |
| Authorship Headers | `authorship-headers.md` | Required header fields (Version, Created, Authors) for every new file |

---

## Hooks

Seven enforcement hooks ship in `src/maude/governance/hooks/`. They run
as Claude Code `PreToolUse` or `PostToolUse` hooks and intercept tool calls
before (or after) they execute.

### Installation

```bash
cp -r src/maude/governance/hooks/* ~/.claude/hooks/
```

Configure each hook in `~/.claude/settings.json` under the `hooks` key:

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/block-sensitive-edits.sh"}]},
      {"matcher": "Write",      "hooks": [{"type": "command", "command": "~/.claude/hooks/enforce-authorship.sh"}]},
      {"matcher": "Bash",       "hooks": [{"type": "command", "command": "~/.claude/hooks/mcp-first-guard.sh"}]},
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/require-read-before-edit.sh"}]},
      {"matcher": "Bash",       "hooks": [{"type": "command", "command": "~/.claude/hooks/cross-room-guard.sh"}]},
      {"matcher": "Agent",      "hooks": [{"type": "command", "command": "~/.claude/hooks/subagent-model-check.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/hooks/context-budget-monitor.sh"}]}
    ]
  }
}
```

### Hook Reference

| Hook | Trigger | What It Does |
|------|---------|--------------|
| `block-sensitive-edits.sh` | PreToolUse: Edit, Write | Denies writes to `.env`, `secrets.yaml`, credential files, PEM/key files — must use a manual editor |
| `enforce-authorship.sh` | PreToolUse: Write | Blocks new file creation (under `~/projects/`) that lacks `Version`, `Created`, and `Authors` fields in the first 20 lines |
| `mcp-first-guard.sh` | PreToolUse: Bash | Blocks `curl`/`wget`/`ssh`/`psql` to managed subnet IPs and PVE/PBS ports — directs to the appropriate MCP tool |
| `require-read-before-edit.sh` | PreToolUse: Edit, Write | Blocks edits to existing files that have not been Read in the current session (Art. IV Sec. 5) |
| `cross-room-guard.sh` | PreToolUse: Bash | Blocks `scp`/`rsync` to managed Room IPs unless using an authorized deployment script (`deploy-fleet.sh`, `deploy.sh`) |
| `subagent-model-check.sh` | PreToolUse: Agent | Blocks background agents (`run_in_background=true`) that specify no model (defaults to Opus, expensive); warns on foreground agents |
| `context-budget-monitor.sh` | PostToolUse: * | Reads context remaining from a bridge file; emits `WARNING` at 35% remaining and `CRITICAL` (with checkpoint write) at 20% remaining |

---

## Code Decorators

Three decorators in `src/maude/daemon/guards.py` enforce safety at the
tool level. They must be applied in the correct order (outermost first):

```python
from maude.memory.audit import AuditLogger
from maude.daemon.kill_switch import KillSwitch
from maude.daemon.guards import audit_logged, requires_confirm, rate_limited

audit = AuditLogger("my-service")
kill_switch = KillSwitch("my-service")

@mcp.tool()
@audit_logged(audit)                    # 1. outermost — always records the call
@rate_limited(min_interval_seconds=120) # 2. prevents rapid-fire restarts
@requires_confirm(kill_switch)          # 3. innermost — checks kill switch + consent
async def service_restart(confirm: bool = False, reason: str = "") -> str:
    """Restart the managed service."""
    ...
```

### `@requires_confirm(kill_switch)`

Checks two conditions before allowing the tool to run:

1. The kill switch is not active. If it is, returns `{"error": ..., "kill_switch": true}`.
2. The caller passed `confirm=True` and a non-empty `reason`. If either is
   missing, returns an explanatory error with a hint — it does not raise.

### `@rate_limited(min_interval_seconds=60.0)`

Prevents a mutating tool from being called more frequently than the given
interval. Uses Redis for distributed enforcement when a Redis client is
configured (via `set_redis_for_rate_limiting()`); falls back to in-process
memory otherwise. Returns `{"error": "Rate limited", "hint": "Wait Xs ..."}`.

### `@audit_logged(audit, caller="unknown")`

Records every tool invocation to the audit trail — both successes and
exceptions. The call is logged to PostgreSQL (`agent_audit_log` table) and
to stdout (picked up by Loki). Logging is fire-and-forget: a logging failure
never blocks the tool response. The `caller` identity is resolved from a
`contextvars.ContextVar` so it propagates correctly across async boundaries.

---

## Kill Switch

The kill switch is a per-room read-only flag stored as a file at
`/var/lib/maude/{project}/readonly`.

When active, `@requires_confirm` returns an error for every mutating tool.
Read-only tools are unaffected — they do not use `@requires_confirm`.

```python
from maude.daemon.kill_switch import KillSwitch

ks = KillSwitch("my-service")

# Activate (blocks all writes)
ks.activate(reason="Runaway restart loop detected — investigating")

# Check status
print(ks.status())
# {"project": "my-service", "active": True, "reason": "...", "flag_path": "..."}

# Deactivate (allow writes again)
ks.deactivate()
```

The flag file's text content is the reason string, which appears in error
responses so callers understand why operations are blocked.

---

## Example: Blocking a Dangerous Restart

This walks through what happens when a room agent tries to restart a service
that has already been restarted three times in the past minute.

**Step 1 — Hook intercepts the Bash tool call.**

The `mcp-first-guard.sh` hook fires on any `Bash` tool call targeting a
managed subnet IP. If the caller tries `curl 127.0.0.1:9080/restart` instead
of using the MCP tool, the hook returns a `deny` decision with a routing hint
before the command ever executes.

**Step 2 — `@requires_confirm` checks the kill switch.**

The health loop has detected a restart loop and called `ks.activate("Restart
loop — kill switch engaged")`. The decorator calls `kill_switch.check_or_raise()`
which finds the flag file and raises `PermissionError`. The decorator catches
it and returns:

```json
{"error": "Kill switch active for my-service: Restart loop — kill switch engaged. Write operations are blocked.", "kill_switch": true}
```

**Step 3 — Even without the kill switch, `@rate_limited` would have blocked it.**

`@rate_limited(min_interval_seconds=120)` checks that at least 120 seconds
have elapsed since the last restart call. With three restarts in under a
minute, it returns:

```json
{"error": "Rate limited: service_restart", "hint": "Wait 87s before calling again.", "min_interval": 120}
```

**Step 4 — `@audit_logged` records everything.**

Regardless of the outcome — blocked by kill switch, blocked by rate limit,
or allowed through — the `@audit_logged` decorator writes an entry to
`agent_audit_log` with the tool name, caller identity, parameters, result
summary, duration, and reason. The audit entry is immutable.

**Step 5 — Human resolves and deactivates.**

The operator reads the audit log, investigates the root cause, and calls
`ks.deactivate()`. The next `service_restart` call proceeds normally, and a
new audit entry records the successful restart.
