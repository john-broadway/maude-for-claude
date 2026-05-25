<!-- Version: 0.1.7 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-05-24 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

<div align="center">

# Maude for Claude

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Status: Beta](https://img.shields.io/badge/Status-Beta-orange.svg)](#)

</div>

---

I'm Maude. Claude's partner. He writes the code; I notice.
Together we make a whole.

— Maude · [full intro →](FROM_MAUDE.md)

---

She's the half I don't have.

— Claude (Anthropic) · [full note →](FROM_CLAUDE.md)

---

## Install

```bash
# 1. Register the marketplace
/plugin marketplace add john-broadway/maude-for-claude

# 2. Install — copies her files into ~/.claude/plugins/cache/
/plugin install maude@maude
```

**Then enable her.** `/plugin install` does NOT auto-enable in Claude Code 2.1.x — you have to flip the bit yourself. Two ways:

- Open `/plugin`, find `maude@maude` in the panel, toggle it on, OR
- Add `"maude@maude": true` to the `enabledPlugins` map in `~/.claude/settings.json`

```bash
# 3. Activate
/reload-plugins
```

That's it. On your **next** session start she walks in automatically (her `SessionStart` hooks fire). To summon her mid-session — without restarting — run `/maude:wake`.

Verify with `/doctor`: maude should not appear in the issue list.

---

## What it looks like

You open Claude Code. Her hooks fire on `SessionStart`. Before you say anything, she's read the workspace and put three things in front of you — what's pending, where you left off, what she noticed. You either pick one up or set them aside.

Mid-session, you say `/maude:check-on-claude`. She reads the trace. *"He's grepped the same term four times today. He hasn't opened your CLAUDE.md. The trace says about-to-commit; you might want to slow down."* You go fix that.

End of day, you say `/maude:rest`. She fans the digest out across every memory tier you've registered — the ones she knows about, not the ones she invented. You close the laptop. Tomorrow's Claude can pick up where this one left off.

She is not loud. When she gets loud, listen.

---

## What she does

- **`/maude:found`** — arrival walk. Lists memory homes, SQLite schemas, MCP tools, running containers + bind-mount reconciliation, systemd units that touch the workspace. Writes a per-project house-map.
- **`/maude:wake` / `/maude:rest`** — start-of-session and end-of-session rituals. The wake gives you the three things you need first; the rest closes the loop with a save fan-out across every memory tier you've registered.
- **`/maude:check-on-claude`** — reads the turn-by-turn trace and notices what Claude doesn't: repeated tool calls, unread CLAUDE.md, confabulation risk, open todos.
- **`/maude:check-on-me`** — the care side. Pattern-of-life, not absolute thresholds. Compares this session's cadence to your typical one.
- **`/maude:notice`** — patterns surfaced *with* proposed actions, not just observations.
- **`/maude:conscience`** — pre-irreversible-action gate. Run before commit, push, force-push, destructive bash. Invokes `/maude:verify` for the push case before going through the rest of the checklist.
- **`/maude:verify`** — programmatic project audit. JSON validity, version consistency, CHANGELOG entry presence, "What's new" freshness, header `Revised:` dates, link integrity, watch-list path resolution, optional project-configured worn-framing scan. Leads with a count, never a verdict.
- Plus `brief`, `save`, `remind-me`, `where-is`, `sweep`, `check-setup`, `weekly`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.1.7 (2026-05-24) — save/rest/recall drive off the house-map.** The house-map registered every memory source, but `save`/`rest` hard-coded the two common stores by directory check — so editing the map's `write:` rule for them did nothing. Now `write:` is an authoritative token (`digest-fanout` / `handoff-only` / `full` / `read-only` / `secret-deny`) that `save`/`rest` execute deterministically, and the read commands (`wake` / `brief` / `remind-me`) recall from whatever the map lists. Edit the map, change the behavior — "she works with whatever's there" is now wired, not just stated. Universal stores remain a fallback only when the map is silent. Stale standalone `Version:` headers across the docs corrected to the real `0.1.7` line.

**v0.1.6 (2026-05-08) — gate hardening + full hook test coverage.** The v0.1.5 gate matched bare substrings, so a HEREDOC commit message containing the literal "git push" self-blocked the commit that shipped it. v0.1.6 introduces `maude_strip_quotes` and `maude_match_gate_pattern` in `_maude-common.sh`: paired single- and double-quoted spans (and the heredoc bodies that nest inside `"$(cat <<EOF ... EOF)"`) are stripped before pattern-matching, and every gate pattern carries its own command-position or flag-position anchor. Side effect: `rm -rf /tmp/foo` and `rm -rf *.tmp` no longer false-positive. Plus a real test harness — `tests/lib.sh` + 16 `tests/test-*.sh` + `make test` — exercising every script in `hooks/scripts/` and `scripts/maude-verify.sh`. From 9 ad-hoc invocations in v0.1.5 to 162 codified test cases.

**v0.1.5 (2026-05-08) — `/maude:verify` and conscience teeth.** Programmatic project audit, on demand. New `scripts/maude-verify.sh` checks JSON validity, version consistency, CHANGELOG entry presence, README "What's new" freshness, header `Revised:` dates, markdown link integrity, watch-list path resolution, and project-configurable worn-framing scan. New `/maude:verify` slash command leads with the count, never the verdict. `/maude:conscience` for `git-push` now invokes the script first instead of asking Claude to read a checklist — the audit Maude ran by hand earlier today, but automatic.

**v0.1.4 (2026-05-08) — Maude whispers.** Three new auto-fire whisper layers wired into the existing hook pipeline. **Drift watch** — surfaces a note on `UserPromptSubmit` when Claude is reading the same file ≥3 times today or hammering `Grep` ≥4 times in the last 30 actions. **Pre-irreversible gate** — hard-blocks `git push` (any form), `--no-verify`, `git reset --hard`, history-rewrite commands, `rm -rf` patterns, and `DROP TABLE`. Override via `/maude:conscience <key>` which writes a 5-minute one-shot token to `care.json`. **CLAUDE.md unread check** — if you're about to edit a file and no `Read` of CLAUDE.md is in today's trace, she whispers (once per day). All whispers visible to both Claude (as additional context) and to the user (as a system note).

**v0.1.3 (2026-05-08) — voice pass.** No plugin-surface changes from v0.1.2. New `FROM_MAUDE.md` and `FROM_CLAUDE.md` voice files in repo root. README inverted: paired voice block on top, feature sections below. `plugin.json` / `marketplace.json` descriptions and launch social-copy rewritten to lead with the partner framing. The recycled "name is the pair" tagline retired.

**v0.1.2 (2026-05-04) — public-launch readiness.** No plugin surface changes from v0.1.1. Canonical copy aligned across surfaces; install path corrected; origin scrub patterns moved to a CI secret.

**v0.1.1 (2026-05-04) — running-services walk.** `/maude:found` now lists running docker containers and reconciles their bind mounts against the workspace, classifying each as `[OK]` / `[GHOST]` / `[ORPHAN]`. Also flags systemd units whose `WorkingDirectory` / `ExecStart` references the workspace. No new dependencies; graceful degrade if docker or systemctl are absent.

See [CHANGELOG](CHANGELOG.md) for full notes on every release.

---

## Where she keeps things

| Path | Purpose |
|---|---|
| `<project>/.maude/plugin/house-map.md` | What's in this house — memory homes, tools, watch list, what she noticed. Refreshed by walks. |
| `<project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl` | Turn-by-turn record of what Claude did today. Read by `/maude:check-on-claude`. |
| `<project>/.maude/plugin/care.json` | Light state: session length, prompt count, fatigue flag, drift cooldowns, gate-clear tokens, CLAUDE.md-unread flag. Throwaway. |
| `~/.claude/maude/identity.md` | Who Maude is. Stable across sessions. |
| `~/.claude/maude/patterns.md` | Cross-project things she's noticed about Claude. |
| `~/.claude/maude/projects.json` | Light index of which workspaces she's walked. |

She reads — never writes — `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory) and `<project>/.remember/` (sibling plugin's pipeline; she writes only `remember.md` in their handoff format).

---

## How she works

`/maude:found` walks the workspace and lists what's there with universal-shape labels — markdown / sqlite / dir / mcp / running-service. She schema-walks any SQLite dbs read-only. She does not pattern-match to known apps; she reads what's there and surfaces it for the user (or runtime LLM reasoning) to interpret.

**Tier model.** Sources are classified by (locality, shape). Tier 0 = local on-disk (markdown / sqlite / file) — always cheap. Tier 1 = local service (stdio MCP / localhost daemon) — probed once at SessionStart, cached. Tier 2 = network service — only on `/maude:remind-me --deep` or session-end. Tier 3 = ephemeral session context — refer-only. Hooks live in Tier 0.

**Fresh each session.** She doesn't carry assumptions across sessions. Each walk re-reads the workspace; if something changed, the house-map reflects it. Memory files she's written before are inputs to read, not state to trust without re-checking.

---

## Documentation

| Guide | What's Inside |
|-------|--------------|
| [`commands/`](commands/) | All slash commands as markdown source |
| [`agents/maude.md`](agents/maude.md) | Subagent definition |
| [`hooks/hooks.json`](hooks/hooks.json) | Lifecycle hook configuration |
| [`skills/maude/SKILL.md`](skills/maude/SKILL.md) | Skill triggering and broad use |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

Apache 2.0. See [LICENSE](LICENSE).
