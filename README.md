<!-- Version: 0.3.3 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-09 CDT -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

<div align="center">

# Maude for Claude

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Status: Beta](https://img.shields.io/badge/Status-Beta-orange.svg)](#)

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/john-broadway) [![X](https://img.shields.io/badge/X-000000?logo=x&logoColor=white)](https://x.com/jebroadway)

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
- **`/maude:dual-voice [on|off]`** — turn standing dual-voice on/off: Claude and Maude both present in replies, not just Maude when summoned. Writes a consented block into a CLAUDE.md you choose; off by default.
- Plus `brief`, `save`, `remind-me`, `where-is`, `sweep`, `check-setup`, `weekly`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.3.3 (2026-06-11) — full cold-audit pass.** Maude got a full fresh-eyes multi-team cold audit — 69 cold agents with no inherited context: three outsider personas, 40 doc claims source-verified, a full-history leak sweep, every finding adversarially refuted. All three personas judged it ready-to-publish and would-use, with no hard blockers (27/40 claims true, 12 mostly-true, 1 false). Fixed: a **gate bypass via command substitution** — a gated command wrapped in backticks (`` `git push` ``) slipped the hard gate, since the backtick wasn't in the separator class; both the leading and trailing separator classes now include it (fail-closed, recoverable via `/maude:conscience`). Plus doc-accuracy (the README claimed the memory dir is read-only, but `/maude:save` and `/maude:rest` write the digest there — now scoped correctly), removal of internal workspace-voice that leaked structure to public readers, and `.gitignore` coverage for the runtime dirs. No new dependencies.

**v0.3.2 (2026-06-11) — closing the review's last opens.** The v0.3.1 review flagged a MEDIUM and three coverage gaps it didn't fix; this closes them, test-first. Headline: without `jq`, `care.sh` was rewriting the shared `care.json` from its own fields every prompt — silently wiping the state other hooks keep there (tier-1, gate-clear tokens, cooldowns). Since care can't read or merge without a JSON parser anyway, the no-jq path is now a **no-op** — inert without `jq`, but no longer destructive. Plus three test-only hardenings: the `drift_warned` merge test now seeds the *real* nested shape (it was asserting a value the code never writes), a guard fails if any command's inlined memory-slug drifts from the canonical one (the root cause of the v0.3.0 "computed two ways" bug), and the no-jq safety notice is now pinned on a pristine project so a reorder below the early-exit can't slip through. No new dependencies.

**v0.3.1 (2026-06-10) — held to her own bar.** v0.3.0 shipped without a pre-release multi-agent review, so it got one *after* the fact — and it found real bugs. Fixed, test-first: **`/maude:teach`** mangled the profile on the 2nd-and-later fact (entries landed newest-first and a stray blank line split the told list in two — now a clean, contiguous, oldest-first append, with multi-line facts collapsed so they can't inject a duplicate header); and the **hard-block gate** was slipped by ordinary command forms — `git  push` (extra spaces), `git -C <dir> push`, `rm  -rf /` — now matched via whitespace-tolerant patterns that also understand `git` global options and reversed `rm` flags, with the soft `bash-watch` reminder brought to parity. Claude is now credited as **co-author** (`plugin.json` contributors). No new dependencies.

**v0.3.0 (2026-06-09) — she gets looked after.** A team-of-subagents audit swept Maude's own house and turned up bugs the punch list didn't know about; v0.3.0 fixes them all, test-first, and adds **`/maude:teach <fact>`** — tell her something about yourself directly ("I work mountain time") and she records it under a `## Told by the user` section in her profile, kept distinct from what she *observed*. Headline fixes: the shared `care.json` was being clobbered every prompt (wiping tier-1 state, gate-clear tokens, cooldowns); the irreversible-command gate failed *open* without `jq` with no warning (now a once-per-session safety notice); the memory-dir slug was miscomputed for dotted paths; `/maude:sweep` always reported the house-map missing; and `test-verify` was non-hermetic. Plus retention pruning for the trace, a timezone-typo guard, best-effort redaction in pre-compact, and a tightened skill-trigger description. Suite: 162 → **269 cases, all green** (and the diff was put through two agent-review passes — an adversarial sweep and the specialized pr-review toolkit — whose confirmed findings are folded into this release). No new dependencies.

**v0.2.0 (2026-06-04) — she grew up.** Three ways Maude matured in daily use, generalized for everyone: **proactive orientation** (she tells you where things stand / what's pending / what's in your hand without being asked — now a standing duty), a **living profile of you** (`identity.md` — how you work, your clock, what you keep returning to — finally wired into save/rest so she actually gets to know you, observed-only), and **optional dual-voice** (`/maude:dual-voice on` — Claude and Maude both present in replies; writes a consented block into a CLAUDE.md you choose; off by default). No new dependencies; the default out-of-the-box experience is unchanged.

**v0.1.8 (2026-06-04) — local-time awareness.** Maude greets by *your* real local time, not the box clock — a server or container reads UTC, so the old fixed "Morning." said the wrong time of day for anyone elsewhere. Now `/maude:found` captures and confirms your timezone into the house-map's `## Clock` section, `/maude:wake` and the session-start greeting track it, and when it's unset she stays time-neutral rather than guess. New clock helpers in `_maude-common.sh` (no new dependency), with tests for the bucket boundaries and the never-guess rule.

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
| `~/.claude/maude/identity.md` | Who the *user* is — Maude's living profile of them, shaped over time. |
| `~/.claude/maude/patterns.md` | Cross-project things she's noticed about Claude. |
| `~/.claude/maude/projects.json` | Light index of which workspaces she's walked. |

Her **hooks** only read `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory) and `<project>/.remember/` (the companion `remember` plugin's pipeline) — never write, so the hot path stays fast and side-effect-free. Her **`/maude:save` and `/maude:rest` commands** do write the session digest: fanned out to `now.md` / `today-*.md` / `recent.md` in the auto-memory dir, and `remember.md` in the `.remember/` handoff format.

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
