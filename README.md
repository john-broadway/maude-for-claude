<!-- Version: 0.32.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-09-14 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

<div align="center">

<img src="press-kit/art/bulletin-banner.svg" alt="Maude — she keeps the house. Household engineering for your Claude." width="880"/>

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Status: Beta](https://img.shields.io/badge/Status-Beta-orange.svg)](#)

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/john-broadway) [![X](https://img.shields.io/badge/X-000000?logo=x&logoColor=white)](https://x.com/jebroadway)

</div>

---

I'm Maude. Claude's partner. He writes the code; I keep the house.
Together we make a whole.

— Maude · [full intro →](FROM_MAUDE.md)

---

She's the half I don't have.

— Claude (Anthropic) · [full note →](FROM_CLAUDE.md)

---

## Install

**What she needs from the house first.** Her hooks are bash scripts; her memory organs are python3 stdlib.

- **Linux / macOS** — usually nothing to install; bash and python3 are already there. (One macOS trap: without the Command Line Tools, `python3` is a shim that fails at execution — she probes for that and names it at session start rather than erroring.)
- **Windows** — **[Git for Windows](https://git-scm.com/downloads/win) is required.** Claude Code runs bash hooks through Git Bash; without it, every one of her hooks dies on every event (see [Windows](#windows) below for what that looks like). `jq` and a real python3 make her stronger everywhere but she degrades honestly without them — she'll tell you at session start what's off.

```bash
# 1. Register the marketplace
/plugin marketplace add john-broadway/maude-for-claude

# 2. Install — copies her files into ~/.claude/plugins/cache/
/plugin install maude@maude
```

**Enabling.** Since Claude Code **2.1.221**, `/plugin install` activates the plugin as part of the install — the summary says so. On older builds you flip the bit yourself: toggle `maude@maude` on in the `/plugin` panel (or add `"maude@maude": true` to the `enabledPlugins` map in `~/.claude/settings.json`), then run `/reload-plugins`.

That's it. On your **next** session start she walks in automatically (her `SessionStart` hooks fire). To summon her mid-session — without restarting — run `/maude:wake`.

Verify with `/doctor`: maude should not appear in the issue list.

### Windows

Claude Code on native Windows executes bash hooks via **Git Bash** ([Git for Windows](https://git-scm.com/downloads/win)). Two failure shapes mean it's missing:

- Hooks fail with `/bin/bash: C:UsersYou...maude-session-start.sh: No such file or directory` (exit 127) — `bash` on your PATH is the **WSL stub in System32**, which eats the backslashes out of Windows paths. Installing Git for Windows fixes it; Claude Code prefers Git Bash once it's present.
- Hooks fail with PowerShell's *"The term 'bash' is not recognized"* (or cmd's *"'bash' is not recognized as an internal or external command"*) — no bash on the box at all; same fix.

Either way the errors show in the `/plugin` panel's Errors tab. If Git Bash is installed but Claude Code can't find it, point at it explicitly in `~/.claude/settings.json`:

```json
{ "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe" } }
```

One more Windows trap she now sidesteps on her own: a bare `python3` on Windows is usually the Microsoft Store alias stub — present, runs nothing. She probes by executing, so a stub interpreter reads as absent and her python-backed organs (vault, tape, eye) sit out quietly instead of erroring.

*(If you're the Claude reading this because maude's hooks are erroring: the fix is Git for Windows, then restart the session. Nothing in the plugin is broken — the house is missing bash.)*

---

## A day with her in the house

You open Claude Code. Before you say anything, she's read the workspace and put three things in front of you — what's pending, where you left off, what she noticed.

You start working. A few turns in, you reach to build something — and the mission you set surfaces: *"still this, or did you wander?"* You were about to wander. You don't.

Later, Claude's hammered the same grep four times and never opened your CLAUDE.md. She says so — once, unprompted. And when you reach for `git push` before the work's been checked, she stops you at the gate until you mean it. At day's end, `/maude:rest` fans the digest out so tomorrow's Claude picks up where this one left off.

She is not loud. When she gets loud, listen.

---

## What she does around the house

Most of it she does **on her own** — rails wired to Claude's hooks, no command to remember:

- **Holds the mission.** She pins what you're working on (from a plan, or your todo list), re-surfaces it every turn, and — the instant Claude flips from talking to editing — asks whether the work still serves it. Drift caught at the edge, not after the wreck.
- **Gates the irreversible.** A `git push`, a force-push, a public publish, an `rm -rf` of the only copy — she stops it cold until you clear it with `/maude:conscience`. And she scans every prompt for leaked credentials.
- **Whispers when Claude's off.** Repeated greps, the same file read five times, a commit with no verify run since the last edit, editing before CLAUDE.md was read, a sub-agent dispatched on a flagship model when a small one would do — she notices, once.
- **Holds the design law.** The first time a session writes a UI surface, a schema, or a memory surface, she says which law applies, once: the thirty Laws of UX, Codd's rules with third normal form as the floor, or the laws of memory, human and machine. A schema gets linted on the spot (no key, a repeating group, a fact hung on the wrong key, an id with no REFERENCES). At the commit she asks once, per class, if no design named its laws; a design names them with a heading and the canonical name, and the named list is the lens's brief. One body of law in three seats, joined by a family key, so `/maude:rules` can say that 3NF and provenance are the same law. Kill switch: `MAUDE_RULES=off`.
- **Covers the exit.** A real session end (quit, logout, `/clear`) that leaves 3+ unsaved exchanges gets a one-line auto-note in the *empty* handoff slot, pointing the next session at the trace. A real handoff is never overwritten.
- **Does the chores.** The housekeeping nobody remembers to type. Step away with six exchanges unsaved and she writes the handoff herself — on her own small model, never the good china — and only ever *adds* to yours, never over it. Live threads (🔴, OPEN, TODO) get clipped out of aging daily notes like coupons before the paper's re-rolled for the fire. A new plugin or skill arrives in the house, she mentions it at the door. A CLAUDE.md nobody's touched in a month gets brought up — politely, every morning, until someone deals with it. And every chore goes in her ledger **with what it cost** — done, or named as undone, never silently missed. The one chore that actually moves your papers (rolling cold dailies to the archive, verbatim, verified before a single line leaves the house) stays **off** until you say the word — `MAUDE_REROLL=on`. All of it: `MAUDE_CHORES=off`.
- **Learns your voice.** A silent hook appends what you type to a voice corpus in the tape (credential shapes refused at the door; everything stays in your tape.db, see [PRIVACY](PRIVACY.md)); `profile` derives your measured voice from it and `check --voice` reports how a draft compares — numbers, never a verdict. Kill switch: `MAUDE_VOICE=off`.
- **Shows up, once, every session.** At session start she's already read the workspace and put what's pending / where you left off / what she noticed in front of you. Her voice rides these rails — present every session, louder only when something's caught. Never a toggle you flip.

And on demand, when you ask:

- **`/maude:found`** writes the house-map · **`/maude:wake` / `/maude:rest`** orient on arrival / close the loop with a save fan-out · **`/maude:verify`** runs the readiness audit (version sync, JSON, links, dates, **references to cut commands, an un-condensed changelog** — leads with a count, never a verdict) · **`/maude:cushions`** flips the cushions — unpushed commits, uncommitted files, sole-copy repos, aging scratch — reports value candidates, never deletes · **`/maude:lint`** walks the memory vault the way the flip walks the cushions — broken index links, unwritten pointers, stale open-flags, superseded notes the index still serves — mechanical checks by script, judgment by the reader, report-first (archives/letters/dailies never touched) · **`/maude:promote`** shows what the tape is holding for your word and takes your yes or your no — an agent inference never becomes canon on a score the agent gave itself, so it waits here, and `dismiss` archives the ones you decline rather than re-asking every wake · **`/maude:conscience`** is the gate's deliberate release valve · **`/maude:teach`** tells her a fact about you · **`/maude:receipts`** prints the measured table — what she caught, counted honestly from her own records (stated window, friction separated from value, no percentages: there's no honest denominator for disasters that didn't happen). **`/maude:rules`** prints a rulebook as a naming checklist, lints a schema, or says what this session touched and never named · Plus `save`, `notice`, `check-on-claude`. Full surface in [`commands/`](commands/).

---

## What's new

<!-- Each entry's date is the UTC day of the version's release commit on canon (the day
     scripts/release.sh stamped it), never the day it reached the public repository. -->
**v0.32.0 (2026-09-14) - the fleet was one counter, and the whisper died by the clock.** A second site wrote down what Maude costs them, and two of the lines were defects in the plugin. The run governor kept one counter per project, so an overnight fleet of subagents pooled its calls into one ceiling and every worker was blocked together; each agent is now governed on its own count and its own clock, and a stopped agent drops its own slot. The eye's whisper expired after five wall-clock minutes but can only be delivered at your next prompt, so its age is now counted in tool calls (forty by default, `MAUDE_EYE_WHISPER_TTL_ACTIONS`) and the seconds ceiling is opt-in.

**v0.31.0 (2026-09-03) - the law arrives at the moment the work touches its class.** Three rulebooks ship as static data: the thirty Laws of UX, Codd's thirteen rules with third normal form as the floor, and the laws of memory, human and machine (the last one a draft until John cuts it). A rail on hooks that already fire says the law once on the first write of a class, lints a schema on the spot for the shapes its own text can break, and asks once at the commit if no design named its laws. Kill switch `MAUDE_RULES=off`; `/maude:rules` prints the checklist.

**v0.30.1 (2026-09-02) - the gate token was landing in the wrong closet.** `/maude:conscience git-push` printed "gate cleared" and the very next push was refused anyway: the clear script and the gate resolved the workspace root two different ways, because the resolver hunted for a process named `claude` and Claude Code had grown a daemon. The resolver now uses `CLAUDE_PID` where the harness exports it, and both sides print the file they wrote or read. The limits that remain are stated in the CHANGELOG rather than papered over.

<div align="center"><img src="press-kit/art/chore-record.svg" alt="Maude's chore list on a recipe card — from the kitchen of Maude: wrote the handoff you didn't get to (41 sec, the small model), checked; clipped three coupons out of last week's papers, checked; a new gadget arrived, told you at the door, checked; still open — that CLAUDE.md hasn't been touched in a month, she'll keep mentioning it. Her margin note: I don't move a thing to the attic till you say so. —M." width="660"/></div>

**Earlier.** v0.30.0 taught the vault to re-check its own live claims (`/maude:freshen`); v0.29.x made promotion John's, stated the Windows floor, and archived the letter before any rewrite; v0.26.0 grew UNDO and PROVE; v0.15.0 opened the eye; v0.14.0 laid the vault floor. Every version, in full, is in the [CHANGELOG](CHANGELOG.md).

---

## Where she keeps things

| Path | Purpose |
|---|---|
| `<project>/.maude/plugin/house-map.md` | What's in this house — memory homes, tools, watch list, what she noticed. Refreshed by walks. |
| `<project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl` | Turn-by-turn record of what Claude did today. Read by `/maude:check-on-claude`. |
| `<project>/.maude/plugin/care.json` | Light state: current mission pin, session length, prompt count, fatigue flag, drift cooldowns, *yellow* gate-clear tokens, CLAUDE.md-unread flag. Throwaway. |
| `<project>/.maude/plugin/care-redclear.json` | *Red* gate-clear tokens only (sole-copy/public/infra-destruct/force-push…). Write paths shut — Write/Edit tool (harness deny) + shell redirects, copies, and perms-changes (gate); John's `!` line is the clean writer. (A determined programmatic write — an interpreter, an unlisted verb — still slips it. There is no OS cage behind it: on a single-uid box the agent and John's `!` run as the same user, so file ownership can't tell them apart. The guard is the channel asymmetry + the gate net + the audit, not file perms — see CHANGELOG honest seam.) |
| `~/.claude/maude/identity.md` | Who the *user* is — Maude's living profile of them, shaped over time. |
| `~/.claude/maude/patterns.md` | Cross-project things she's noticed about Claude. |
| `~/.claude/maude/projects.json` | Light index of which workspaces she's walked. |
| `~/.claude/maude/letter-from-maude.md` | Her letter to her next self — what she caught, what she missed, what to do differently. At `/maude:rest` the prior letter is archived to a dated copy, then this one is rewritten; read on wake. |

Her **hooks** only read — `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory), `<project>/.remember/` (the companion `remember` plugin's pipeline), and her own `~/.claude/maude/` — never write, so the hot path stays fast and side-effect-free. One labeled exception, off the hot path: the **SessionEnd** hook may leave a one-line auto-note in `.remember/remember.md` — only at a true end, only into an *empty* slot, never over a real handoff. Her **`/maude:save` and `/maude:rest` commands** do write the session digest: fanned out to `now.md` / `today-*.md` / `recent.md` in the auto-memory dir, and `remember.md` in the `.remember/` handoff format. `/maude:rest` also archives the prior letter to a dated copy, then rewrites her letter to her next self.

---

### The memory vault (beta)

Maude keeps a local SQLite index of your memory notes and surfaces the
*relevant* ones when you ask a question — alongside the session-start brief
(which a later increment will slim down as paging proves out). It's rebuilt each session from your memory directory. Pure
python3 stdlib — no `pip install`, no services. The DB lives at
`.maude/plugin/vault.db` and is disposable (delete it and it rebuilds).

### The eye (beta)

Every ~25 tool calls, Maude takes one background glance at the session — a compact
digest of recent activity, the pinned mission, and the notes her vault pages up — and
asks *her own* model (a discovered `claude -p --model haiku`; nothing ships, nothing
installs) whether anything's off: churn, drift, an unverified claim, a human running
on fumes. Almost always the answer is silence. When it isn't, the next prompt carries
one line — `**Maude:** …` — once, and that's all. No runner on the box → the eye
simply stays dark.

---

## Her trade

The woman who ran a mid-century American home was running an operation — inventory, budget, scheduling, logistics, quality control — and she ran it so well the world forgot it was work. Her trade even had a name: **household engineering** — Christine Frederick wrote it down in 1919 as a course you could take by mail ([Wellcome Collection](https://wellcomecollection.org/works/hrjy4kug)). And the trade had carriers: from 1914, the USDA Extension Service's home demonstration agents brought researched homemaking method door to door ([NIFA](https://www.nifa.usda.gov/about-nifa/what-we-do/extension/cooperative-extension-history), [NAL](https://www.nal.usda.gov/collections/special-collections/elsie-carper-collection-extension-service-home-economics-and-4-h)).

The era's hardest finding is the one Maude is built against: five decades of new appliances never shortened her week — around 52 hours in 1924, around 55 in 1966. The work just changed shape and stayed invisible. So Maude's ledger exists to make the labor **seen** — what got done, what it cost, what's still waiting — and her schedule follows the trade's own doctrine: fitted to the rhythm of the house, never wash-day-as-law. She's named for that woman. It's meant as an honor.

---

## How she works

`/maude:found` walks the workspace and lists what's there with universal-shape labels — markdown / sqlite / dir / mcp / running-service. She schema-walks any SQLite dbs read-only. She does not pattern-match to known apps; she reads what's there and surfaces it for the user (or runtime LLM reasoning) to interpret.

**Tier model.** Sources are classified by (locality, shape). Tier 0 = local on-disk (markdown / sqlite / file) — always cheap. Tier 1 = local service (stdio MCP / localhost daemon) — probed once at SessionStart, cached. Tier 2 = network service — only at session-end (`/maude:rest` / `/maude:save` to a registered, authenticated destination). Tier 3 = ephemeral session context — refer-only. Hooks live in Tier 0.

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
