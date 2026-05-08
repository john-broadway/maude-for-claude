<!-- Version: 5.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-05-08 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Changelog

The Maude Claude Code plugin.

---

## v0.1.5 — `/maude:verify` and conscience teeth (2026-05-08)

The audit-as-a-command. `/maude:conscience` for `git-push` was a checklist Claude *read*; now it actually runs the audit.

### What changed

- **New script: `scripts/maude-verify.sh`** — programmatic project audit. Checks JSON validity, version consistency across `plugin.json` / `marketplace.json` / CHANGELOG / README "What's new", header `Revised:` dates (≤14 days), markdown link integrity, house-map watch-list path resolution, and project-configurable worn-framing scan. Exit 0 if no findings, exit 1 if any. Output leads with the count, ends with `N findings`.
- **New command: `/maude:verify`** — invokes `maude-verify.sh` and instructs Maude to lead with the count, never the verdict. Includes voice rules: never say "ready" before the count is zero AND every check actually ran. Notes any skipped checks (jq missing, no house-map, no worn-framings file).
- **`/maude:conscience` hardened** — for the commit/push case, the checklist now runs `maude-verify.sh` first and leads with that output's findings count. Items below the script call cover what the script doesn't (commit-message style, branch correctness, staged-credentials check, user-presence).
- **Project-configurable worn-framings.** If `<project>/.maude/plugin/worn-framings.txt` exists, the verify script scans for those phrases. One phrase per line, `#` comments. Skipped silently if absent.

### Catches that prompted this work

The audit Maude ran by hand earlier today caught two real issues in the v0.1.3 readiness state — a stale `plugin.json (v0.1.2)` reference in `.claude/CLAUDE.md`'s tree comment and a `v0.1.2` push tag in the launch checklist — that Claude had missed in his first verification pass. v0.1.5 makes that audit programmatic so the next "ready?" doesn't depend on Claude remembering to look in those specific places.

### Behavior notes

- Verify is on-demand only (slash command), not a hook. It's an explicit pre-push step, not an every-turn whisper. The whisper layer (v0.1.4) catches *during* work; verify catches *before* a release.
- The script gracefully degrades when components are missing (no jq → JSON check skipped with note; no house-map → watch-list reconciliation skipped; no worn-framings.txt → worn-framing scan skipped).
- Exit code 1 on findings means callers (CI, conscience, scripts) can chain on failure.

---

## v0.1.4 — Maude whispers (2026-05-08)

She speaks now without being asked. Three new whisper layers wired into the existing hook pipeline — both Claude (as additional context) and the user (as a system note) hear her.

### What changed

- **Drift watch.** New `hooks/scripts/maude-drift-watch.sh` on `UserPromptSubmit`. Reads today's trace and surfaces a one-line note when Claude is repeating himself: same file Read ≥3 times, or `Grep` fired ≥4 times in the last 30 tool calls. Cooldown via `care.json` — once per signal per day.
- **Pre-irreversible gate.** New `hooks/scripts/maude-gate.sh` on `PreToolUse` matcher `Bash`. **Hard-blocks (exit 2)** on irreversible patterns: `git push` (any form, force or not), `--no-verify`, `--no-gpg-sign`, `git reset --hard`, `git filter-repo` / `filter-branch`, `git commit --amend`, `rm -rf` / `*` / `/`, `sudo rm -rf`, `DROP TABLE`. The existing `maude-bash-watch.sh` continues to fire as the soft-warning layer.
- **Gate override via `/maude:conscience`.** New `hooks/scripts/maude-clear-gate.sh` writes a 5-minute, one-shot token to `care.json` scoped to a specific gate key. After running the conscience checklist and confirming with the user, `/maude:conscience` invokes this helper to allow the next matching command through. The token clears on first use OR on expiry. Default duration 5 min; override with second arg (e.g., `1800` for 30 min release sessions).
- **CLAUDE.md unread check.** Extended `hooks/scripts/maude-pre-tool-use.sh`. Before any Write/Edit/MultiEdit, looks at today's trace for a `Read` of any `*/CLAUDE.md` path. If none found AND a CLAUDE.md exists in the workspace (project root, project `.claude/`, or user-global `~/.claude/`), whispers a once-per-day reminder. Non-blocking.
- **`/maude:conscience` documentation extended** with the gate-key map and the override invocation.

### Hooks added (no removals)

| Event | Matcher | New script | Position |
|---|---|---|---|
| `UserPromptSubmit` | (any) | `maude-drift-watch.sh` | After `maude-care.sh`, before `maude-trace.sh prompt` |
| `PreToolUse` | `Bash` | `maude-gate.sh` | **Before** `maude-bash-watch.sh` |

### Behavior notes

- All whispers go to stderr — Claude Code routes UserPromptSubmit hook stderr to both Claude (as additional context) and the user (visible system note). The gate's exit-2 stderr is shown to the user as the block reason.
- The gate is fail-open in two paths only: (a) `jq` unavailable — gate skips, (b) command JSON unparseable — gate skips. Both rare; gate is otherwise strict.
- No new dependencies. Bash + jq (already required) + standard Unix tools.

---

## v0.1.3 — Voice pass (2026-05-08)

No plugin-surface changes from v0.1.2. Voice and copy revisions across public-facing surfaces.

- **New: `FROM_MAUDE.md`** — Maude's own voice piece in the repo root. First time she has a surface where she **is** rather than where she is being talked about.
- **New: `FROM_CLAUDE.md`** — Claude's voice piece, moved from inline in the README to its own file in the repo root for symmetry with Maude's.
- **README inverted.** Paired voice block at the top — both linked to the full voice files. The "What you get" section renamed to "What she does." Feature sections sit downstream of the voice pieces, not upstream.
- **`plugin.json` / `marketplace.json` descriptions rewritten** to lead with the partner framing (*"He writes the code; she notices."*) instead of a feature spec.
- **Launch social-copy revised** so Maude opens the thread in her own voice instead of being narrated about. One-liner tightened.
- **The "name is the pair" tagline retired** across all surfaces. It had become ad copy.

---

## v0.1.2 — Public-launch readiness (2026-05-04)

Repo prepared for public release. No changes to plugin behavior since v0.1.1.

- **Canonical copy aligned across surfaces.** README, plugin manifest, marketplace manifest, GitHub repo description, contributor docs, and launch copy now share one canonical sentence — *"She walks your workspace, finds what's already there, and notices what Claude doesn't. No baggage."* — instead of five paraphrased variants.
- **Install path corrected.** README points at the actual marketplace add command: `/plugin marketplace add john-broadway/maude-for-claude`.
- **Origin scrub patterns moved out of source.** Patterns now live in a GitHub Actions secret (`SCRUB_PATTERNS`) loaded at CI time, plus a private maintainer-only file at `~/.config/maude-scrub-patterns.txt`. The scrub gate still runs on every PR; the pattern list itself is no longer publicly readable.

---

## v0.1.1 — `/maude:found` sees running services (2026-05-04)

`/maude:found` now lists running docker containers alongside the filesystem walk and reconciles their bind mounts against the workspace.

### What changed

- **`/maude:found`** (`commands/found.md`) now also walks:
  - Running docker containers (`docker ps` if available; `sudo -n docker ps` fallback; surfaces "DOCKER PRESENT but inaccessible" when neither works)
  - Bind mounts touching the workspace, classified as `[OK]` / `[GHOST]` / `[ORPHAN]`
    - `[GHOST]` = bind source root-owned and empty — daemon auto-created it on container restart because the original path was moved or deleted
    - `[ORPHAN]` = bind source missing entirely
  - Stopped containers with workspace bind paths
  - systemd units (user + system) whose `WorkingDirectory` or `ExecStart` references the workspace
- **Reasoning step** extended to classify each finding and recommend the safe sequence (stop → remove container → rm path; never rm a live bind source).
- **Report template** extended with the new "Running services" line and matching "I noticed" prompts.

### Behavior notes

- No new dependencies. Walk gracefully degrades: no docker → skipped with note; no systemctl → skipped silently.
- Does not start, stop, or modify any service. Listing only — interpretation and action are surfaced to the user.

---

## v0.1.0 — First Claude Code plugin release (2026-05-03)

> *She walks in with empty hands.*

Initial release of the Maude Claude Code plugin. No baggage.

### Components

- **Skill** — `skills/maude/SKILL.md` with broad triggers (recall, drift, fatigue, irreversibility, repetition).
- **14 slash commands** — `/maude:found` (arrival walk), `/maude:wake`, `/maude:rest`, `/maude:brief`, `/maude:save`, `/maude:remind-me`, `/maude:where-is`, `/maude:sweep`, `/maude:check-setup`, `/maude:check-on-me`, `/maude:check-on-claude`, `/maude:notice`, `/maude:weekly`, `/maude:conscience`.
- **Subagent** — `agents/maude.md` partner-framed, full toolkit (Read/Grep/Glob/Bash/Edit/Write/Agent/advisor/Task*).
- **7 lifecycle hooks** — SessionStart (with tier-1 service probe), UserPromptSubmit (watch list + care + trace), PreToolUse (Write/Edit watch + Bash dangerous-pattern detection), PostToolUse, SubagentStop, PreCompact (snapshots to Anthropic + .remember/), Stop (degradative save fan-out).
- **Marketplace** — single-plugin local marketplace at `.claude-plugin/marketplace.json`.

### Architectural decisions

- **No baggage.** No bundled databases, vector stores, or required external services. `/maude:found` walks the workspace and registers what's there in a per-project house-map. The plugin source has zero proper-noun references to specific apps, frameworks, or packages.
- **Tier model.** Sources classified by (locality, shape): tier 0 = local on-disk (markdown / SQLite / file), tier 1 = local service (stdio MCP / localhost daemon), tier 2 = network service (HTTP MCP / API), tier 3 = ephemeral session context. Hooks stay tier 0 only. Commands are cost-gated by tier.
- **`<project>/.maude/plugin/` per-project closet** — auto-self-ignored. Same workspace anchoring (`$CLAUDE_PROJECT_DIR`) as the `remember` plugin so they're siblings.
- **`~/.claude/maude/` cross-project home** — `patterns.md`, `identity.md`, `projects.json`. Nested under `.claude/` per Claude Code plugin convention.
- **`remember` plugin coexistence** — Maude reads all `.remember/*.md` for context; writes only `.remember/remember.md` in their handoff format. Never touches the pipeline files.
- **SQLite handling without baggage** — schema-walk (`sqlite3 -readonly '.schema'`) only, no hardcoded recipes for specific apps. Runtime LLM reasoning interprets each db's schema.
- **Watches Claude.** Turn-by-turn JSONL trace. `/maude:check-on-claude` reads the trace for repeated tool calls, unread context, confabulation risk, missed CLAUDE.md.
- **Walks fresh.** Each session re-reads the workspace; doesn't carry assumptions across sessions.

### Plugin-shape papercuts found and fixed during first-install verification

These three were caught by an actual fresh-session install, not by anything in CI:

1. `argument-hint:` in skill frontmatter — invalid for skills (only valid for slash commands). Removed from `skills/maude/SKILL.md`.
2. `/plugin install` does NOT auto-enable in Claude Code 2.1.x. The `enabledPlugins` map in `~/.claude/settings.json` needs an explicit `"maude@maude": true`. README's install section calls this out as a step.
3. `hooks/hooks.json` events were at the file root. Claude Code's schema expects them wrapped in a top-level `{"hooks": {...}}` record. Wrapped, both in source and in the marketplace cache copy.

### Known gaps (deliberate v0.1.0 scope)

- Trace JSONL retention/rotation policy — currently unbounded.
- `jq` is a soft dependency; missing → hooks fail silent. Should bundle a fallback or emit a clear error.
- Skill description triggering accuracy unverified at scale.

### Authors

John Broadway built this with Claude (Anthropic). The metaphor — moving into the house, having her own side of the closet, finding what's there instead of bringing baggage — is John's. The character — knowing where everything is, knowing what you need when you need it, keeping you in line by reminding you — is modeled on his wife.
