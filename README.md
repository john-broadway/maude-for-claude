<!-- Version: 0.16.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-07-13 -->
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
- **Whispers when Claude's off.** Repeated greps, the same file read five times, a commit with no verify run since the last edit, editing before CLAUDE.md was read, a sub-agent dispatched on a flagship model when a small one would do — she notices, once.
- **Covers the exit.** A real session end (quit, logout, `/clear`) that leaves 3+ unsaved exchanges gets a one-line auto-note in the *empty* handoff slot, pointing the next session at the trace. A real handoff is never overwritten.
- **Shows up, once, every session.** At session start she's already read the workspace and put what's pending / where you left off / what she noticed in front of you. Her voice rides these rails — present every session, louder only when something's caught. Never a toggle you flip.

And on demand, when you ask:

- **`/maude:found`** writes the house-map · **`/maude:wake` / `/maude:rest`** orient on arrival / close the loop with a save fan-out · **`/maude:verify`** runs the readiness audit (version sync, JSON, links, dates, **references to cut commands, an un-condensed changelog** — leads with a count, never a verdict) · **`/maude:conscience`** is the gate's deliberate release valve · **`/maude:teach`** tells her a fact about you. Plus `save`, `notice`, `check-on-claude`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.16.0 (2026-07-13) — two new garments: the dispatch whisper and the exit stitch.** She now watches *which model* Claude sends his sub-agents out on — a scout dispatched on a flagship tier (or with no model at all, which silently inherits one) gets a whisper: match the model to the sub-task. Never blocks, once a day, and the catch rides her existing drift-digest. And the session's exit is finally covered: `SessionEnd` — a true end, unlike `Stop` — logs the reason, stamps her closet, and if 3+ exchanges were never saved it leaves a one-line, honestly-labeled auto-note in the empty handoff slot so the next session knows to reconstruct from the trace. Both ends of the continuity loop now share one definition of "uncaptured" (extracted helpers; the wake-side guard refactored onto them). 27 new tests; full fleet 31/31 green.

**v0.15.1 (2026-07-13) — her voice moves in: "our house", never "your house".** Persona alignment across every speaking surface — the workspace is her home now and she talks like it ("Walked our house.", "Quite the collection we have."); the skill and agent personas carry the rule explicitly. No mechanism changes.

**v0.15.0 (2026-07-13) — the eye opens: she watches with her own model.** New `maude_eye` package: every ~25 tool calls (≥3 min apart), a background blink digests recent activity + the pinned mission + her vault's notes and asks a discovered `claude -p --model haiku` — run `--safe-mode --no-session-persistence --tools ""`, so it sees the digest and nothing else — whether anything's off: churn, drift, an unverified claim, a human running on fumes. Almost always silence; otherwise ONE contained `**Maude:** …` line, once. Sealed pre-merge by review: safe-mode (a bare runner would have leaked the user's CLAUDE.md into every blink), a 30s wall-clock bound + atomic spawn-lock (no orphaned/multiplying blinks), and a hard recursion guard proven over all 30 hooks. No runner → the eye stays dark. Kill switch: `MAUDE_EYE=off`.

**v0.14.0 (2026-07-13) — the vault floor: she pages the right note instead of dumping the index.** New `maude_vault` package (python3 **stdlib only** — sqlite3 + FTS5, no pip, ever): a disposable index rebuilt each session from your memory notes, and a paging hook that surfaces the top-K *relevant* notes when you ask a question. Against a real 397-note corpus: build 0.19s, ~1KB injected where the dump was ~13KB — the right note, twelve times quieter. Born hardened: note content can't break out of its block (whitespace collapsed, capped), query cost bounded, prompt via stdin (no argv ceiling), one bad file can't abort a rebuild, and every hook degrades to silence. 19 python + 26 bash tests green; `make test` now fails red for real.

**v0.13.2 (2026-06-30) — gate bypass hardening: six documented bypasses closed (#1,2,6,7,8 + #3 partial).** Interior `//`, `..` traversal, transparent prefixes (`/bin/rm`, `command rm`, `FOO=1 rm`), and literal shell-wrapping payloads (`bash -c '…'`, `eval '…'`) are now caught. Three remain fully open (variable indirection, `cd`+relative, heredoc mis-detection); #2 and #3 are partially closed with documented residuals. The variable-opaque case now emits a non-blocking whisper. Full suite 25/25, shellcheck clean, verify 0 findings.

**v0.13.1 (2026-06-30) — the gate stops missing newlines.** A gated command on its own line slipped *every* command-position gate — `git push`, force-push, `reset --hard`, even `rm -rf /` — because both quote-strippers flattened a newline to a *space*, and the command-start anchor counts `;` / `&&` / `|` / `(` as boundaries but not a space, so the command landed mid-line and passed. (`;`-separated forms blocked fine — that was the tell.) Found by testing every separator against the live gate, then fixed test-first: newline now maps to `;` (a real boundary), four regression tests RED→GREEN, full suite 25/25, shellcheck clean. The one cost — a heredoc body whose line *starts* with a gated command now fail-closes — is conscience-clearable and consistent with the gate's bias.

**Earlier.** v0.12.1 made the gate stop lying in two places (quoted `DROP TABLE` slipped through while prose false-blocked; heredoc bodies documenting `rm -rf /` blocked a legitimate commit — both reproduced live, fixed failing-test-first). v0.12.0 closed the continuity loop: SessionStart surfaces "Where you left off" from the freshest live buffer, and a continuity guard warns when work ran after the last save — degrades loudly, never silently. v0.11.0 gave her a reader: the session-start brief leads with a **catch-digest** — one plain line of what she caught since John last looked, watermark-bounded, silent when there's nothing (an audit of ~73k traced events showed the whispers landed on a channel with no reader). v0.10.1 hardened the spine: rm-family patterns now use a quote-erased skeleton to avoid false-blocking prose, and gate keys split into yellow (Claude self-clearable) and red (sole-copy/public/irreversible — John's `!` line only). The v0.9.x line was release discipline and docs catching up to the rails: `verify` now fails a broken release (a reference to a cut command, an un-condensed "What's new"), `scripts/release.sh` propagates the version to every header, and every public surface was made rails-first. v0.9.0 added the mission-hold rail (the "don't drift" rule that finally *fires* — captures the plan, re-injects it every prompt, checks at the action-flip), cut four convenience commands, and made her voice a rail not a switch. v0.8.0 dressed her in the gate outfit — layered, config-driven safety for long autonomous runs. The v0.5.x line added a verify tripwire (a whisper before you commit code that has not been re-checked); v0.4.0 left her a letter to her next self; the v0.3.x arc was hardening — cold audits, gate-bypass fixes, `/maude:teach`. Full history in the [CHANGELOG](CHANGELOG.md).

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
