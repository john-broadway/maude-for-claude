<!-- Version: 0.9.1 -->
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
- **Her voice rides the rails** — she speaks beside Claude when a hook catches something, and lands at least once every session in the start-up greeting. Not a toggle you flip.
- Plus `save`, `remind-me`, `sweep`, `weekly`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.9.1 (2026-06-19) — release discipline: misses get gated, not remembered.** v0.9.0 shipped, and then the public README still carried all 24 old "What's new" entries and two references to commands we'd just cut — because the release was hand-walked across a dozen files, and hand-walking misses. So we made the misses impossible to *ship* instead of impossible to *forget*: `verify` (already a required CI check) now also fails on a reference to a command that no longer exists and on an un-condensed "What's new" wall — a broken release can't merge. And `scripts/release.sh <version>` (`make release VERSION=…`) propagates the version to every header, stamps the dates, and runs the gate, so the mechanical part stops depending on a person remembering. The copy below is condensed to match.

**v0.9.0 (2026-06-19) — the mission-hold rail, and Maude taking her own medicine.** This one started with a failure, not a feature: Maude had rules in memory (*use what you own, keep it simple*) that nothing ever **fired**, so Claude would settle on the right plan and drift off it within a few turns. The new **mission-hold rail** (`maude-mission.sh`) makes the rule fire — it **captures** the mission from an `ExitPlanMode` plan or the active `TodoWrite` item, **holds** it by re-injecting `MISSION: <x>` every prompt (so it can't scroll out of view), **verifies** at the action-flip (*"still this, or did you wander?"*), and **clears** each session. No drift-detector — that'd be the over-engineering it exists to fight. Then we turned the same honesty on Maude and found she'd caught the disease she cures: a dozen commands, most of them conveniences with a turnstile bolted on. So we **cut four** (`brief`, `where-is`, `check-setup`, `dual-voice`) and made her **voice a rail, not a switch** — the `SessionStart` greeting now always lands, even on a stranger's first run, so her once-per-session presence can't be skipped and never depended on a toggle. One capability added, ~320 lines gone, four fewer commands, a voice that's present instead of summoned.

**Earlier.** v0.8.0 dressed her in the gate outfit — layered, config-driven safety for long autonomous runs. The v0.5.x line added a verify tripwire (a whisper before you commit code that has not been re-checked); v0.4.0 left her a letter to her next self; the v0.3.x arc was hardening — cold audits, gate-bypass fixes, `/maude:teach`. Full history in the [CHANGELOG](CHANGELOG.md).

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
