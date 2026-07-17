<!-- Version: 0.21.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-07-17 -->
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
- **Covers the exit.** A real session end (quit, logout, `/clear`) that leaves 3+ unsaved exchanges gets a one-line auto-note in the *empty* handoff slot, pointing the next session at the trace. A real handoff is never overwritten.
- **Does the chores.** The housekeeping nobody remembers to type. Step away with six exchanges unsaved and she writes the handoff herself — on her own small model, never the good china — and only ever *adds* to yours, never over it. Live threads (🔴, OPEN, TODO) get clipped out of aging daily notes like coupons before the paper's re-rolled for the fire. A new plugin or skill arrives in the house, she mentions it at the door. A CLAUDE.md nobody's touched in a month gets brought up — politely, every morning, until someone deals with it. And every chore goes in her ledger **with what it cost** — done, or named as undone, never silently missed. The one chore that actually moves your papers (rolling cold dailies to the archive, verbatim, verified before a single line leaves the house) stays **off** until you say the word — `MAUDE_REROLL=on`. All of it: `MAUDE_CHORES=off`.
- **Shows up, once, every session.** At session start she's already read the workspace and put what's pending / where you left off / what she noticed in front of you. Her voice rides these rails — present every session, louder only when something's caught. Never a toggle you flip.

And on demand, when you ask:

- **`/maude:found`** writes the house-map · **`/maude:wake` / `/maude:rest`** orient on arrival / close the loop with a save fan-out · **`/maude:verify`** runs the readiness audit (version sync, JSON, links, dates, **references to cut commands, an un-condensed changelog** — leads with a count, never a verdict) · **`/maude:cushions`** flips the cushions — unpushed commits, uncommitted files, sole-copy repos, aging scratch — reports value candidates, never deletes · **`/maude:conscience`** is the gate's deliberate release valve · **`/maude:teach`** tells her a fact about you · **`/maude:receipts`** prints the measured table — what she caught, counted honestly from her own records (stated window, friction separated from value, no percentages: there's no honest denominator for disasters that didn't happen). Plus `save`, `notice`, `check-on-claude`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.21.0 (2026-07-17) — the punch list and the proving ground.** Her user filed the backlog — Claude wrote five GitHub issues against her from live field use (#34–#38) — and this release answers them: the extension roster seats only real plugins (a live roster carried 191 lines of installer transients wearing plugin names), a whisper past its TTL is dropped with a receipt instead of wearing a fresh voice, the catch-count now ends with a path to its receipts (`Receipts: /maude:notice`), and the wake brief reads the last cushion-flip from a closet stamp — with the flip and the brief now resolving the project the same way, so they can never stamp different closets. New proving ground: `make smoke` stages a git-archive of HEAD — the shape a stranger actually installs — and proves it validates as a plugin, passes its own fleet from inside the archive, and greets cold from a pristine HOME; a clean working tree is not a clean commit. Release pages now mint themselves from the CHANGELOG when a tag lands, CodeQL watches the shipped python, every CI action is SHA-pinned. Known and filed, not hidden: macOS portability (#39). Three new test files; fleet 43.

**v0.20.0 (2026-07-16) — the chore ledger: her hands.** Until now she noticed and warned; now the housekeeping nobody typed gets *done*. Four chores, one ledger in her closet. **The save nobody typed:** leave six exchanges uncaptured and her own small model reads the day and writes the handoff — into an empty slot, or appended under her own dated heading; a handoff you wrote is never overwritten, and on a house without the `remember` substrate she skips and says so rather than building a room uninvited. **The coupon-cut:** live 🔴/OPEN/TODO lines clipped out of aging dailies before anything is re-rolled — exact lines, deduped, kept in her `coupons.md`. The re-roll itself (cold dailies moved to archive — copied, byte-compared, and only then removed, with a failed move logged as failed, never as done) ships **off until you hand her the key**. **The new-arrivals watch:** plugins and skills that came to the house since you last looked. **The stale-CLAUDE.md flag:** stays on her list, out loud, until someone acts. Every finished chore stamps its cost — and a failed one is stamped failed, with the reason; concurrent chores can't lose each other's entries (one ledger, one lock); and a standing fence now fails the whole test fleet if any `claude -p` in this repo forgets to pin its model. Nine new test files.

<div align="center"><img src="press-kit/art/chore-record.svg" alt="Maude's chore list on a recipe card — from the kitchen of Maude: wrote the handoff you didn't get to (41 sec, the small model), checked; clipped three coupons out of last week's papers, checked; a new gadget arrived, told you at the door, checked; still open — that CLAUDE.md hasn't been touched in a month, she'll keep mentioning it. Her margin note: I don't move a thing to the attic till you say so. —M." width="660"/></div>

**v0.19.0 (2026-07-15) — value before the dustpan, and the cushion-flip.** Her retention sweep no longer trashes by calendar alone: a pre-compact snapshot (content, possibly the only copy of an unsaved session) is deleted only when a *later save covers it* — uncovered snapshots wait for a save, not a birthday. And a new ritual, **`/maude:cushions`**, reaches where no sensor watches: unpushed commits, uncommitted files, LOCAL-ONLY repos (sole-copy risk, said plainly), aging scratch. It reports value candidates and never deletes — the trash decision stays human. A `.parked` file names change that's in the cushion on purpose, so deliberate parks are stated once, never re-flagged. 20 new tests.

**v0.18.1 (2026-07-15) — the wake brief stops crying wolf.** The one cross-project pattern the session-start brief surfaces was picked by grepping for the project's name — any entry whose *body* contained it (a path was enough) pinned forever, truncated mid-sentence into what read like a live alert. The picker now rotates through the entry headings by day-of-year: every scar gets airtime, and a dated heading self-identifies as history instead of breaking news. Three new tests pin it.

**v0.18.0 (2026-07-14) — the memory loop closes.** The vault could recall but never revise: a rule superseded weeks ago still paged as live, and "the"/"with"/"what" matched everything. Now `superseded_by:` frontmatter retires a note from recall without touching the markdown (mark, don't erase); ranking weighs recency and note type beside BM25 (durable rules outrank old letters; stopwords are out); the pager tallies every recall to `recall-log.jsonl` and the rest ritual sweeps the top-fired notes for staleness — serve → check → revise. And the eye's model is unpinned: `MAUDE_EYE_MODEL` steers the blink; haiku is the default, never a requirement.

**v0.17.0 (2026-07-13) — the dispatch whisper learns workflows.** A workflow script's `agent()` calls never pass through the Agent tool, and stock/named harnesses set no `model:` — so every fan-out agent silently inherits the flagship. She now reads the script (inline or on disk) and whispers once when `agent()` calls carry no `model:`; for a *named* workflow she can't inspect, the whisper carries the recovery rule instead (grab the persisted `scriptPath`, grep for `model:`, tier before the expensive phase). Separate cooldown from the Agent whisper. Never blocks.


**Earlier.** v0.16.0 added the dispatch whisper (she watches which model sub-agents ride out on — a flagship-tier scout gets one non-blocking nudge: match the model to the sub-task) and the exit stitch (`SessionEnd` logs the reason, stamps her closet, and leaves an honestly-labeled auto-note when 3+ exchanges were never saved). v0.15.0 opened the eye — a `maude_eye` package where every ~25 tool calls a background blink digests recent activity + the pinned mission + her vault's notes and asks a discovered `claude -p --model haiku` (run `--safe-mode --no-session-persistence --tools ""`) whether anything's off; almost always silence, otherwise ONE contained line; sealed pre-merge with a 30s bound, atomic spawn-lock, and a recursion guard proven over all 30 hooks (`MAUDE_EYE=off` kills it). v0.14.0 laid the vault floor — a `maude_vault` package (python3 **stdlib only**: sqlite3 + FTS5, no pip, ever), a disposable index rebuilt each session from your memory notes that pages the top-K *relevant* notes instead of dumping the index (~1KB injected where the dump was ~13KB, against a real 397-note corpus), born hardened and degrading to silence. v0.12.1 made the gate stop lying in two places (quoted `DROP TABLE` slipped through while prose false-blocked; heredoc bodies documenting `rm -rf /` blocked a legitimate commit — both reproduced live, fixed failing-test-first). v0.12.0 closed the continuity loop: SessionStart surfaces "Where you left off" from the freshest live buffer, and a continuity guard warns when work ran after the last save — degrades loudly, never silently. v0.11.0 gave her a reader: the session-start brief leads with a **catch-digest** — one plain line of what she caught since John last looked, watermark-bounded, silent when there's nothing (an audit of ~73k traced events showed the whispers landed on a channel with no reader). v0.10.1 hardened the spine: rm-family patterns now use a quote-erased skeleton to avoid false-blocking prose, and gate keys split into yellow (Claude self-clearable) and red (sole-copy/public/irreversible — John's `!` line only). The v0.9.x line was release discipline and docs catching up to the rails: `verify` now fails a broken release (a reference to a cut command, an un-condensed "What's new"), `scripts/release.sh` propagates the version to every header, and every public surface was made rails-first. v0.9.0 added the mission-hold rail (the "don't drift" rule that finally *fires* — captures the plan, re-injects it every prompt, checks at the action-flip), cut four convenience commands, and made her voice a rail not a switch. v0.8.0 dressed her in the gate outfit — layered, config-driven safety for long autonomous runs. The v0.5.x line added a verify tripwire (a whisper before you commit code that has not been re-checked); v0.4.0 left her a letter to her next self; the v0.3.x arc was hardening — cold audits, gate-bypass fixes, `/maude:teach`. Full history in the [CHANGELOG](CHANGELOG.md).

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
| `~/.claude/maude/letter-from-maude.md` | Her letter to her next self — what she caught, what she missed, what to do differently. Rewritten at `/maude:rest`, read on wake. |

Her **hooks** only read — `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory), `<project>/.remember/` (the companion `remember` plugin's pipeline), and her own `~/.claude/maude/` — never write, so the hot path stays fast and side-effect-free. One labeled exception, off the hot path: the **SessionEnd** hook may leave a one-line auto-note in `.remember/remember.md` — only at a true end, only into an *empty* slot, never over a real handoff. Her **`/maude:save` and `/maude:rest` commands** do write the session digest: fanned out to `now.md` / `today-*.md` / `recent.md` in the auto-memory dir, and `remember.md` in the `.remember/` handoff format. `/maude:rest` also rewrites her letter to her next self.

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
