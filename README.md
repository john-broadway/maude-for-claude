<!-- Version: 0.13.2 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-24 -->
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

- **`/maude:found`** writes the house-map · **`/maude:wake` / `/maude:rest`** orient on arrival / close the loop with a save fan-out · **`/maude:verify`** runs the readiness audit (version sync, JSON, links, dates, **references to cut commands, an un-condensed changelog** — leads with a count, never a verdict) · **`/maude:conscience`** is the gate's deliberate release valve · **`/maude:teach`** tells her a fact about you. Plus `save`, `notice`, `check-on-claude`. Full surface in [`commands/`](commands/).

---

## What's new

**v0.13.2 (2026-06-30) — gate bypass hardening: six documented bypasses closed (#1,2,6,7,8 + #3 partial).** Interior `//`, `..` traversal, transparent prefixes (`/bin/rm`, `command rm`, `FOO=1 rm`), and literal shell-wrapping payloads (`bash -c '…'`, `eval '…'`) are now caught. Three remain fully open (variable indirection, `cd`+relative, heredoc mis-detection); #2 and #3 are partially closed with documented residuals. The variable-opaque case now emits a non-blocking whisper. Full suite 25/25, shellcheck clean, verify 0 findings.

**v0.13.1 (2026-06-30) — the gate stops missing newlines.** A gated command on its own line slipped *every* command-position gate — `git push`, force-push, `reset --hard`, even `rm -rf /` — because both quote-strippers flattened a newline to a *space*, and the command-start anchor counts `;` / `&&` / `|` / `(` as boundaries but not a space, so the command landed mid-line and passed. (`;`-separated forms blocked fine — that was the tell.) Found by testing every separator against the live gate, then fixed test-first: newline now maps to `;` (a real boundary), four regression tests RED→GREEN, full suite 25/25, shellcheck clean. The one cost — a heredoc body whose line *starts* with a gated command now fail-closes — is conscience-clearable and consistent with the gate's bias.

**v0.13.0 (2026-06-26) — audit punch-list closed.** Three remaining items, done together. Four commands the audit found unused across ~73k events — `remind-me`, `sweep`, `weekly`, `check-on-me` — are gone (surface 13 → 9; recall now rides the hooks + `/maude:wake`). The red-clear gate net caught `>`/`tee` but missed `cp`/`mv`/`dd` — it now blocks those plus `chattr`/`chmod`/`ln`, and the old "OS ownership is the real lock" line is **retired for the truth**: on a single-uid box the agent and John's `!` line are the same user, so there is no OS cage — only the channel asymmetry (`!` skips the tool-gate), the net, and the audit. And the test runner is now hermetic: a `MAUDE_*` toggle left in your shell can no longer leak in and flip a test.

**v0.12.1 (2026-06-26) — the gate stops lying in two places.** The gate's only value is accuracy, and the audit found two spots where it lied. `DROP TABLE` was exactly backwards: it matched the quote-*erased* command, but real SQL is always quoted (`psql -c "DROP TABLE x"`) — so it **slipped through** while an unquoted *prose* mention false-blocked. Now it matches the content-kept view and only fires in a real SQL-client context, so quoted SQL blocks and a commit message mentioning the words passes. And a `git commit -F -` whose body *documented* `rm -rf /` got blocked — heredoc bodies weren't being treated as the data they are; the rm-guard now excises them before deciding whether an `rm` is genuinely executing. Both reproduced against the live gate, failing-test-first, then fixed.

**v0.12.0 (2026-06-24) — the continuity loop closes.** Continuity is what lets Maude wake Claude oriented — but "is there a loop protecting that?" found two gaps, both caught by dogfooding the real workspace: the wake path was reading a lagging buffer and an empty handoff while the freshest capture sat unread, and nothing verified continuity at all (the Stop hook writes no handoff, so a clean quit without `/maude:rest` could wake the next session under-informed, silently). Fixed both — SessionStart now surfaces a **"Where you left off"** line from the freshest live buffer (`$REMEMBER/now.md`), and a new **continuity guard** reconciles the last capture against real trace activity, warning at the top of the brief when work ran after the last save. Continuity degrades loudly, not silently; on a healthy system the guard stays quiet.

**v0.11.0 (2026-06-24) — she gets a reader.** An evidence-grounded audit of ~73,000 traced events found the honest shape of "she does nothing": the gates genuinely bite (six organic `rm -rf` saves of the sole copy, a fail-closed infra-gate), but ~99.7% of what Maude does aims at Claude and never reaches John — the advisory whispers land on a channel with no reader. So the session-start brief now leads with a **catch-digest**: one plain line of what she caught since John last looked — `1 sole-copy save, 2 blocks, 1 drift-catch (+3 push-clears, 14 verify-flags)` — value-first, the volume folded into a tail, silent when there's nothing. It's watermark-bounded (counted from the trace, advancing each session) so resume/compact never re-print the same catch. Makes the whispers *visible*, not *fewer* — the first reader, where there was none.

**Earlier.** v0.10.1 hardened the spine: rm-family patterns now use a quote-erased skeleton to avoid false-blocking prose, and gate keys split into yellow (Claude self-clearable) and red (sole-copy/public/irreversible — John's `!` line only). The v0.9.x line was release discipline and docs catching up to the rails: `verify` now fails a broken release (a reference to a cut command, an un-condensed "What's new"), `scripts/release.sh` propagates the version to every header, and every public surface was made rails-first. v0.9.0 added the mission-hold rail (the "don't drift" rule that finally *fires* — captures the plan, re-injects it every prompt, checks at the action-flip), cut four convenience commands, and made her voice a rail not a switch. v0.8.0 dressed her in the gate outfit — layered, config-driven safety for long autonomous runs. The v0.5.x line added a verify tripwire (a whisper before you commit code that has not been re-checked); v0.4.0 left her a letter to her next self; the v0.3.x arc was hardening — cold audits, gate-bypass fixes, `/maude:teach`. Full history in the [CHANGELOG](CHANGELOG.md).

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

Her **hooks** only read — `~/.claude/projects/<slug>/memory/` (Anthropic auto-memory), `<project>/.remember/` (the companion `remember` plugin's pipeline), and her own `~/.claude/maude/` — never write, so the hot path stays fast and side-effect-free. Her **`/maude:save` and `/maude:rest` commands** do write the session digest: fanned out to `now.md` / `today-*.md` / `recent.md` in the auto-memory dir, and `remember.md` in the `.remember/` handoff format. `/maude:rest` also rewrites her letter to her next self.

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
