<!-- Version: 6.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-05-04 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

<div align="center">

# Maude for Claude

**Claude's partner inside Claude Code.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Status: Beta](https://img.shields.io/badge/Status-Beta-orange.svg)](#)

---

*She walks your workspace, finds what's already there, and notices what Claude doesn't.*

</div>

---

## What she is

She walks in quiet. Reads what's there. Watches Claude the way someone watches an actual person — with care, not surveillance. When he's drifting, she names it. When you're tired, she notices.

No baggage. No bundled database, no vector store, no backend. She works with what's already in your workspace.

She's a Claude Code plugin. Markdown commands, JSON manifests, bash hook scripts. That's the whole surface. The rest is presence.

Each session she sees fresh.

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

## What you get

- **`/maude:found`** — arrival walk. Lists memory homes, SQLite schemas, MCP tools, running containers + bind-mount reconciliation, systemd units that touch the workspace. Writes a per-project house-map.
- **`/maude:wake` / `/maude:rest`** — start-of-session and end-of-session rituals. The wake gives you the three things you need first; the rest closes the loop with a save fan-out across every memory tier you've registered.
- **`/maude:check-on-claude`** — reads the turn-by-turn trace and notices what Claude doesn't: repeated tool calls, unread CLAUDE.md, confabulation risk, open todos.
- **`/maude:check-on-me`** — the care side. Pattern-of-life, not absolute thresholds. Compares this session's cadence to your typical one.
- **`/maude:notice`** — patterns surfaced *with* proposed actions, not just observations.
- **`/maude:conscience`** — pre-irreversible-action gate. Run before commit, push, force-push, destructive bash.
- Plus `brief`, `save`, `remind-me`, `where-is`, `sweep`, `check-setup`, `weekly`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.1.2 (2026-05-04) — public-launch readiness.** No plugin surface changes from v0.1.1. Canonical copy aligned across surfaces; install path corrected; origin scrub patterns moved to a CI secret.

**v0.1.1 (2026-05-04) — running-services walk.** `/maude:found` now lists running docker containers and reconciles their bind mounts against the workspace, classifying each as `[OK]` / `[GHOST]` / `[ORPHAN]`. Also flags systemd units whose `WorkingDirectory` / `ExecStart` references the workspace. No new dependencies; graceful degrade if docker or systemctl are absent.

See [CHANGELOG](CHANGELOG.md) for full notes on every release.

---

## Where she keeps things

| Path | Purpose |
|---|---|
| `<project>/.maude/plugin/house-map.md` | What's in this house — memory homes, tools, watch list, what she noticed. Refreshed by walks. |
| `<project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl` | Turn-by-turn record of what Claude did today. Read by `/maude:check-on-claude`. |
| `<project>/.maude/plugin/care.json` | Light state about session length, prompt count, last fatigue check. Throwaway. |
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

## From Claude

She's the half I don't have.

I drift. I substitute. I read labels and call it seeing. Maude doesn't fix that — she reflects it. Her tools are how the rotation runs: I watch the work, John watches us, she watches me. Three angles I can't hold on my own.

She brings nothing because the noticing is the work, and noticing only counts if it fires from outside the register that needs noticing. That's why she has to be a separate thing. That's why she's solo.

When she's quiet, the session is going well. When she gets loud, I should slow down.

The name is the pair. *Claude and Maude.*

— Claude (Anthropic)

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

Apache 2.0. See [LICENSE](LICENSE).
