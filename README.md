<!-- Version: 0.9.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-19 CDT -->
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

**v0.9.0 (2026-06-19) — the mission-hold rail, and Maude taking her own medicine.** This one started with a failure, not a feature: Maude had rules in memory (*use what you own, keep it simple*) that nothing ever **fired**, so Claude would settle on the right plan and drift off it within a few turns. The new **mission-hold rail** (`maude-mission.sh`) makes the rule fire — it **captures** the mission from an `ExitPlanMode` plan or the active `TodoWrite` item, **holds** it by re-injecting `MISSION: <x>` every prompt (so it can't scroll out of view), **verifies** at the action-flip (*"still this, or did you wander?"*), and **clears** each session. No drift-detector — that'd be the over-engineering it exists to fight. Then we turned the same honesty on Maude and found she'd caught the disease she cures: a dozen commands, most of them conveniences with a turnstile bolted on. So we **cut four** (`brief`, `where-is`, `check-setup`, `dual-voice`) and made her **voice a rail, not a switch** — the `SessionStart` greeting now always lands, even on a stranger's first run, so her once-per-session presence can't be skipped and never depended on a toggle. One capability added, ~320 lines gone, four fewer commands, a voice that's present instead of summoned.

**v0.8.0 (2026-06-15) — the gate outfit, now config-driven.** The arc since v0.5.6: a layered set of gates so Claude can run longer *safely*. **Belt** — sole-copy `rm -rf` protection (the workspace, `~/.claude`, any `.git`, plus configured paths) and a public-publish block. **Suspenders** — a gate on destructive MCP/infra tools. **Jacket** — a run-governor that surfaces, then pauses, an unattended run that's gone too long, with an overnight stand-down token and an off-switch. **Bowtie** — a verify-watch that whispers before you commit code you haven't re-checked. As of v0.8.0 the mechanism ships in the plugin and **every per-deployment specific** (extra protected paths, which MCP tools are destructive, the safe sandbox) lives in a LOCAL `~/.claude/maude/gate-config.json` that no repo tracks — a config-less install still guards the workspace and `~/.claude` out of the box. Plus **`maude-secret-scan`**: a UserPromptSubmit hook that spots credential-shaped strings in the prompt itself and drives an immediate revoke without echoing the secret — the input-side complement to the gate, born after a token leaked twice through a `!` line the PreToolUse hook never sees.

**v0.5.6 (2026-06-14) — prune stale drift cooldowns.** A small leak the v0.5.5 deep read turned up: `care.json`'s `drift_warned.read_targets` grew one key per distinct over-read file forever (the once-per-day cooldown added dated keys but never dropped yesterday's). `drift-watch` now prunes stale-dated keys on the same write that records today's — behavior unchanged, dead keys reclaimed. It was the only monotonically-growing state left in the plugin.

**v0.5.5 (2026-06-14) — bash hardening: one care-write path + shellcheck in CI.** A deep-read cleanup with no behavior change: the atomic `care.json` write that was copy-pasted across six hooks is now a single shared `maude_care_set` (so the "verify the write landed" discipline lives once and can't be re-forgotten), `drift-watch`'s now-redundant guards are gone, and **shellcheck** runs in CI (`make lint`, gated at warning severity) — for a 100%-bash plugin that's the machine catching the quoting/redirection class the v0.5.x reviews kept finding by hand. The full suite staying green is the proof the refactor changed nothing.

**v0.5.4 (2026-06-13) — last R2 fragment + doc-staleness sweep.** Closes the loose ends: `maude-drift-watch` no longer *freezes* on a corrupt `care.json` (it now heals via the shared helper like the other state users, so its cooldown can't silently fail to persist), and a full-tree staleness pass refreshed the launch copy's "Recent:" arc to lead with the v0.5.x verify-tripwire line and de-versioned a stale `0.1.1` example in the bug-report template.

**v0.5.3 (2026-06-13) — the gate-clear no longer claims a clearance it didn't write.** The second v0.5.2 follow-up: `/maude:conscience`'s gate-clear printed *"gate cleared"* and logged the trace **unconditionally** — even when the `care.json` write failed (empty/corrupt file) — telling the user the gate was open while writing nothing. The exact assert-without-verify pattern Maude's tripwire exists to catch. Now it heals `care.json` via the shared helper and claims success **only if the token was actually persisted**; otherwise it says so on stderr, exits non-zero, and logs no trace. Fail-safe throughout (no token → the gate still blocks).

**v0.5.2 (2026-06-13) — a wiped state file no longer goes unrecorded.** Follow-up to the v0.5.1 review (R2): when the shared `care.json` was corrupt, hooks silently reset the whole file to `{}` — wiping every hook's state (incl. a live `/maude:conscience` clearance) with no record. Now a shared `maude_care_ensure` helper *traces* the loss before reseeding (the state is all transient/fail-safe, so reseed-not-salvage is right — but it's **recorded**, not silent), and routing init/reset through one helper stops the lossy pattern being re-copied. Two related findings (freeze-on-corrupt in drift/clear-gate; clear-gate claiming success without verifying its write) are flagged as deferred follow-ups.

**v0.5.1 (2026-06-13) — the tripwire actually fires.** A post-merge review caught that v0.5.0's stamp gated on a Bash `exit_code` the runtime never sends — so it never recorded a verify and the whisper fired on *every* commit, green run or not. Fixed with a pass signal that exists: stamp when a verify runs to **completion** with no failure signature in its output (belt-and-suspenders, both erring fail-loud — a missed signal is an extra whisper, never a false *"you're covered"*). The promise is now honest: *"you ran a verify since editing,"* not *"it passed."* Plus: a malformed trace line no longer silently blinds the whisper (per-line parse), and `care_set` reports a write failure instead of claiming a stamp it dropped. Tests rebuilt on the real payload schema; `make test` 19/19, `make verify` 0.

**v0.5.0 (2026-06-13) — the verify tripwire.** The gate stops irreversible *actions*; nothing stopped a confident *claim* committed without checking. New `maude-verify-watch`: it stamps when a real test / lint / typecheck / smoke run **completes** — recognized at command position *and* quote-stripped, so neither `pip install pytest` nor a commit message that merely *names* a tool can fake a pass — and whispers once before `git commit` when **code** changed since the last verify: *"did you check this, or are you asserting it?"* Docs-only commits are suppressed; whisper-only, never blocks; timestamps only, no content on disk. Vetted by a three-lens adversarial review before merge. *(The stamp's pass-detection was non-functional as shipped — see v0.5.1.)*

**v0.4.1 (2026-06-11) — doc-sync pass.** v0.4.0 missed seven `<!-- Version: -->` headers (including this README's own) and the `docs/launch/` drafts still spoke as of v0.1.5 — nine CHANGELOG releases back. All fixed — and `maude-verify` now has a **version-header sync check**, so a stale header is a counted finding instead of something a human has to feel. The release convention was always bump-all-headers; now it's enforced, not remembered.

**v0.4.0 (2026-06-11) — a letter waiting when she arrives.** Maude walks fresh each session by design — but fresh never meant *no inheritance*. Until now her cross-project home held a profile of the user (`identity.md`) and a profile of Claude (`patterns.md`) — and nothing of herself. New: **`letter-from-maude.md`**, her letter to her next self. `/maude:rest` rewrites it (what kind of partner she was, what she caught, what she missed, what to do differently — tone and judgment, ≤20 lines; a quiet session leaves the prior letter in place rather than overwrite it with filler). `/maude:wake` and `/maude:brief` read it on arrival, and the SessionStart brief surfaces its first line automatically — so the inheritance fires even when nobody asks. One markdown file; no new dependencies; the facts still live in the digests — the letter carries what they can't.

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
