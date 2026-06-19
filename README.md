<!-- Version: 0.9.2 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-19 -->
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

You open Claude Code. Before you say anything, she's read the workspace and put three things in front of you — what's pending, where you left off, what she noticed.

You start working. A few turns in, you reach to build something — and the mission you set surfaces: *"still this, or did you wander?"* You were about to wander. You don't.

Later, Claude's hammered the same grep four times and never opened your CLAUDE.md. She says so — once, unprompted. And when you reach for `git push` before the work's been checked, she stops you at the gate until you mean it. At day's end, `/maude:rest` fans the digest out so tomorrow's Claude picks up where this one left off.

She is not loud. When she gets loud, listen.

---

## What she does

Most of it she does **on her own** — rails wired to Claude's hooks, no command to remember:

- **Holds the mission.** She pins what you're working on (from a plan, or your todo list), re-surfaces it every turn, and — the instant Claude flips from talking to editing — asks whether the work still serves it. Drift caught at the edge, not after the wreck.
- **Gates the irreversible.** A `git push`, a force-push, a public publish, an `rm -rf` of the only copy — she stops it cold until you clear it with `/maude:conscience`. And she scans every prompt for leaked credentials.
- **Whispers when Claude's off.** Repeated greps, the same file read five times, a commit with no verify run since the last edit, editing before CLAUDE.md was read — she notices, once.
- **Shows up, once, every session.** At session start she's already read the workspace and put what's pending / where you left off / what she noticed in front of you. Her voice rides these rails — present every session, louder only when something's caught. Never a toggle you flip.

And on demand, when you ask:

- **`/maude:found`** writes the house-map · **`/maude:wake` / `/maude:rest`** orient on arrival / close the loop with a save fan-out · **`/maude:verify`** runs the readiness audit (version sync, JSON, links, dates, **references to cut commands, an un-condensed changelog** — leads with a count, never a verdict) · **`/maude:conscience`** is the gate's deliberate release valve · **`/maude:teach`** tells her a fact about you. Plus `save`, `remind-me`, `sweep`, `notice`, `check-on-claude`, `check-on-me`, `weekly`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.9.2 (2026-06-19) — the docs caught up to the rails.** v0.9.0/v0.9.1 shipped the mission-hold rail and the rails-not-commands reframe, but the prose still described the old command-centric Maude — "What she does" didn't mention the rail, "What it looks like" told you to *summon* her, and SKILL.md / agents.md / the marketplace pitch omitted it. Made every public surface current: a rails-first "What she does," a reframed "What it looks like," and the mission rail now present in the skill, the agent (whose hook list was also missing the gate), and the plugin description. Prose only — no runtime change.

**v0.9.1 (2026-06-19) — release discipline: misses get gated, not remembered.** v0.9.0 shipped, and then the public README still carried all 24 old "What's new" entries and two references to commands we'd just cut — because the release was hand-walked across a dozen files, and hand-walking misses. So we made the misses impossible to *ship* instead of impossible to *forget*: `verify` (already a required CI check) now also fails on a reference to a command that no longer exists and on an un-condensed "What's new" wall — a broken release can't merge. And `scripts/release.sh <version>` (`make release VERSION=…`) propagates the version to every header, stamps the dates, and runs the gate, so the mechanical part stops depending on a person remembering. The copy below is condensed to match.

**v0.9.0 (2026-06-19) — the mission-hold rail, and Maude taking her own medicine.** This one started with a failure, not a feature: Maude had rules in memory (*use what you own, keep it simple*) that nothing ever **fired**, so Claude would settle on the right plan and drift off it within a few turns. The new **mission-hold rail** (`maude-mission.sh`) makes the rule fire — it **captures** the mission from an `ExitPlanMode` plan or the active `TodoWrite` item, **holds** it by re-injecting `MISSION: <x>` every prompt (so it can't scroll out of view), **verifies** at the action-flip (*"still this, or did you wander?"*), and **clears** each session. No drift-detector — that'd be the over-engineering it exists to fight. Then we turned the same honesty on Maude and found she'd caught the disease she cures: a dozen commands, most of them conveniences with a turnstile bolted on. So we **cut four** (`brief`, `where-is`, `check-setup`, `dual-voice`) and made her **voice a rail, not a switch** — the `SessionStart` greeting now always lands, even on a stranger's first run, so her once-per-session presence can't be skipped and never depended on a toggle. One capability added, ~320 lines gone, four fewer commands, a voice that's present instead of summoned.

**Earlier.** v0.8.0 dressed her in the gate outfit — layered, config-driven safety for long autonomous runs. The v0.5.x line added a verify tripwire (a whisper before you commit code that has not been re-checked); v0.4.0 left her a letter to her next self; the v0.3.x arc was hardening — cold audits, gate-bypass fixes, `/maude:teach`. Full history in the [CHANGELOG](CHANGELOG.md).

---

## Where she keeps things

| Path | Purpose |
|---|---|
| `<project>/.maude/plugin/house-map.md` | What's in this house — memory homes, tools, watch list, what she noticed. Refreshed by walks. |
| `<project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl` | Turn-by-turn record of what Claude did today. Read by `/maude:check-on-claude`. |
| `<project>/.maude/plugin/care.json` | Light state: current mission pin, session length, prompt count, fatigue flag, drift cooldowns, gate-clear tokens, CLAUDE.md-unread flag. Throwaway. |
| `~/.claude/maude/identity.md` | Who the *user* is — Maude's living profile of them, shaped over time. |
| `~/.claude/maude/patterns.md` | Cross-project things she's noticed about Claude. |
| `~/.claude/maude/projects.json` | Light index of which workspaces she's walked. |
| `~/.claude/maude/letter-from-maude.md` | Her letter to her next self — what she caught, what she missed, what to do differently. Rewritten at `/maude:rest`, read on wake. |

Her **hooks** only read — `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory), `<project>/.remember/` (the companion `remember` plugin's pipeline), and her own `~/.claude/maude/` — never write, so the hot path stays fast and side-effect-free. Her **`/maude:save` and `/maude:rest` commands** do write the session digest: fanned out to `now.md` / `today-*.md` / `recent.md` in the auto-memory dir, and `remember.md` in the `.remember/` handoff format. `/maude:rest` also rewrites her letter to her next self.

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
