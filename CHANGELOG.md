<!-- Version: 0.9.2 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-19 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Changelog

The Maude Claude Code plugin.

---

## v0.9.2 — 2026-06-19

**The docs caught up to the rails.**

v0.9.0/v0.9.1 shipped the mission-hold rail and the rails-not-commands reframe — but the *prose* still described the old command-centric Maude. "What she does" was a command list that didn't even mention the rail; "What it looks like" told you to *summon* her with `/maude:check-on-claude`; and SKILL.md, agents/maude.md, and the marketplace pitch omitted the rail entirely. Classic miss-and-repeat: fix the section you're looking at, miss the one beside it.

- **README "What she does"** now leads with the rails she runs on her own — holds the mission, gates the irreversible, whispers when Claude's off, shows up once a session — then the on-demand commands. **"What it looks like"** reframed to what she does *unprompted*, not what you summon.
- The **mission-hold rail now appears across every surface**: SKILL.md, agents/maude.md (whose hook list was also missing the gate), and the `plugin.json` / `marketplace.json` description.
- README "What's new" condensed alongside (the v0.9.1 gate keeps it ≤ 6).

Prose only — no change to hooks or commands. And the cause is named: currency now gets a deliberate whole-surface pass each release, because the gate catches *structural* misses (dangling refs, the wall) but not "this description is stale."

### Changed
- README "What she does" + "What it looks like" rewritten rails-first.
- mission-hold rail documented in SKILL.md, agents/maude.md, and the plugin/marketplace description.

---

## v0.9.1 — 2026-06-19

**Release discipline — the misses get gated, not remembered.**

v0.9.0 shipped correctly, but the public README still carried all 24 old "What's new" entries and two references to commands we'd just cut. Not a one-off slip: every release was hand-walked across ~12 files (bump each version header, stamp dates, match marketplace.json, add the changelog + What's-new entry, condense the old ones, scrub references to anything cut) — and hand-walking from memory misses. So we moved the release from "a person remembering" to "a mechanism that can't forget."

- **`verify` now gates the misses** — and it runs as a required CI check, so a broken release can't merge. On top of the version-header sync it already enforced, it fails on (a) a `/maude:<name>` reference in README/SKILL/agent to a command that no longer has a `commands/<name>.md` (the cut-command straggler), and (b) an un-condensed "What's new" — more than 6 release entries means the wall wasn't trimmed.
- **`scripts/release.sh <version>`** (`make release VERSION=…`) — the updater: sets the version in `plugin.json` + `marketplace.json`, propagates it to every `<!-- Version: -->` header, stamps the `Revised:` dates, and runs the gate (verify + test + lint). It writes no prose — the CHANGELOG and What's-new entries stay ours — and it never pushes; it stops at "ready for PR."
- **Condensed the README "What's new"** from 24 stacked entries to the current two plus a one-line "Earlier" pointer here, which also cleared the dangling `/maude:brief` and `/maude:dual-voice` references the new gate flagged.

No change to the plugin's runtime — hooks and commands are untouched. This is release-process hardening: the public face stays fluid and consistent because the gate won't let it drift.

### Added
- `verify` checks: command-reference integrity + "What's new" condensation.
- `scripts/release.sh` + `make release VERSION=…`.

### Changed
- README "What's new" condensed (24 → 2 + "Earlier").

---

## v0.9.0 — 2026-06-19

**The mission-hold rail — and Maude taking her own medicine.**

This one started with a failure, not a feature. Maude exists to keep Claude honest — but she had rules sitting in memory (*use what you own, keep it simple*) that nothing ever **fired**. Claude would settle on the right plan and then drift off it within a few turns, and the rule that should have caught the drift never ran. Storing a rule is not the same as the rule gating the answer. So we built the thing that makes it fire.

**The mission-hold rail** (`maude-mission.sh`) — one pinned mission, four touches, all riding hooks that already existed:
- **capture** — pins the mission from the only two places it's already structured data: an `ExitPlanMode` plan or the active `TodoWrite` item. Sticky; only those replace it.
- **hold** — re-injects `MISSION: <x>` every prompt, so it can't scroll out of view (the reason it faded even right after wake).
- **verify** — at the action-flip (the first `Write`/`Edit`/`Bash` after a stretch of talking), whispers the pinned mission: *still this, or did you wander?*
- **clear** — wipes it at `SessionStart`, fresh each session.

Honest about the seam: detecting the flip is deterministic; auto-capturing the *text* only works from the plan/todo payloads; the "am I drifting" judgment stays Claude's. No drift-detector — that would have been the exact over-engineering this release exists to fight.

**Then we turned the same honesty on Maude, and found she'd caught the disease she's built to cure.** A dozen commands had piled up — most of them conveniences with a turnstile bolted on, value you had to *remember to summon*. And her "voice" was a toggle you flipped, not a presence that was simply there. So:
- **Cut four commands** — `brief` (the `SessionStart` greeting already is it), `where-is` (just ask), `check-setup` (folded into `sweep`), and `dual-voice`.
- **Her voice is a rail now, not a switch.** It never came from the dual-voice toggle — it comes from her hooks. We made the once-per-session presence unskippable: the `SessionStart` greeting now lands even on a stranger's first run on an empty project. She's voiced on signal — when a hook catches something — and guaranteed once a session. Never a per-turn echo.

Net: one real capability added, ~320 lines removed, four fewer commands, a voice that's present instead of summoned. She got lighter and more honest in the same move. That was the point.

Built test-first; the suite is green, shellcheck is clean, and her own `verify` reports zero findings. Design note in `docs/specs/`.

### Added
- `maude-mission.sh` + wiring — the mission-hold rail (`capture` / `hold` / `verify` / `clear`).
- Guaranteed once-per-session voice: `SessionStart` always greets, even on a pristine project.
- `tests/test-mission.sh` — 11 cases.

### Changed
- `maude-session-start.sh` always greets (removed the silent early-exit).
- `sweep` now also covers `.claude/` setup (absorbed `check-setup`).

### Removed
- Commands: `brief`, `where-is`, `check-setup`, `dual-voice`.

---

## v0.8.0 — 2026-06-15

**Gates are now config-driven — the plugin carries no deployment specifics.** The gate MECHANISM ships in the plugin; per-deployment specifics (extra sole-copy paths, which MCP tools are destructive, the safe sandbox nodes/vmids) live in a LOCAL `~/.claude/maude/gate-config.json` (override `$MAUDE_GATE_CONFIG`), tracked by no repo.
- **Belt:** sole-copy `rm -rf` protection now covers generic defaults — the current workspace dir, `~/.claude`, and any `.git` — plus any paths listed in the local gate-config. No hardcoded paths in the source.
- **Infra-gate:** reads the destructive-tool set, the MCP server prefix, and the sandbox from the local gate-config. With no config it is INERT (nothing gated). Its matcher now covers all MCP tools (`mcp__.*`); the script filters by the configured prefix.
- **jq note:** the infra-gate needs `jq` to read its config, so without `jq` it is inert (fail-open) rather than fail-closed; the belt keeps its existing fail-open-without-jq contract; the catastrophic backstop for destructive infra remains a harness-level `permissions.deny` (applied separately by the operator).
- No behavior change for an existing deployment that supplies a gate-config; the defaults make a config-less install protect the workspace + `~/.claude` out of the box.

### Added
- **`maude-secret-scan` hook (UserPromptSubmit)** — scans each submitted prompt for credential-shaped strings (PyPI / GitHub / AWS / Slack / OpenAI / Anthropic / Google tokens, private-key blocks) and, on a match, alerts Claude to drive an immediate **revoke** — without ever echoing the secret value. Detection + fast-revoke, not prevention (by the time any hook runs the text is already submitted; the win is a much smaller exposure window). Born after a credential leaked twice via a `!` command — the `maude-gate` PreToolUse hook only sees Claude's *tool calls*, not user-typed `!` lines, so this watches the input surface instead. Never blocks; tuned so prose mentions of tokens don't trip it.

---

## v0.7.1 — 2026-06-15

**Run-governor: overnight stand-down + off-switch.** So an intentional long/unattended run isn't blocked by the ceiling.
- A live `/maude:conscience run-governor <seconds>` token now stands the governor DOWN for its whole window (no soft, no hard) instead of buying a single fresh budget — e.g. `run-governor 36000` = run free for 10h, logged. A human turn still resets; the token rides until it expires.
- New `MAUDE_RUN_GOVERNOR=off` (also `0`/`false`/`no`) env disables the governor entirely (set in settings.json `env` for a deployment/session that never wants it). Default stays ON.
- When disabled, the governor now announces itself once at SessionStart (so an off brake is never silent).

---

## v0.7.0 — 2026-06-15

**The gate outfit, Phase 2 — jacket + bowtie.** The layers that make "run longer" safe to actually use.
- **Jacket — `maude-run-governor.sh`:** counts tool-actions + wall-clock since your last turn (UserPromptSubmit resets it). Soft checkpoint whisper at 40 actions / 40 min; **hard-pause** (blocks) at 80 actions / 90 min until a human turn or `/maude:conscience run-governor` (fresh budget). Thresholds env-tunable (`MAUDE_RUN_SOFT_ACTIONS/MINS`, `MAUDE_RUN_HARD_ACTIONS/MINS`). The conscience escape-hatch command is exempt so the ceiling can't deadlock. Advisory layer → fails OPEN without jq.
- **Bowtie — `maude-verify-watch.sh stop`:** on a Stop, a soft one-line reminder if code changed since the last verify (reuses the commit-mode detection; cooldowned per edit-batch so it isn't noisy). Never blocks.
- New conscience key: `run-governor`.

### Known limitations
- The governor counts Claude's tool-calls as the activity proxy; a long single tool call advances wall-clock but not the action count — the minutes ceiling covers that.
- `Stop` fires on every assistant pause, so the bowtie can only *remind*, not detect a true session-end; the cooldown holds it to once per edit-batch.
- The governor is advisory (fail-open without jq); catastrophic protection remains the belt + suspenders + harness-deny.

---

## v0.6.0 — 2026-06-15

**The gate outfit (Phase 0 + 1)** — dressing Maude with layered, *coordinated* gates so Claude can run long unattended without an irreversible mistake slipping through.

### Added / changed
- **Shared danger-palette** in `_maude-common.sh` (the RoE zones expressed once: sole-copy paths, public-publish commands, configurable destructive MCP tool set, configured sandbox). Belt and the new suspenders draw from it. (The shoes/`maude-bash-watch.sh` refactor onto the palette is deferred to a follow-on; a parity test currently locks the belt/shoes match on the *core* danger set — rm -rf /, force-push, sudo rm — only.)
- **Belt (`maude-gate.sh`) now hard-blocks**, in addition to its prior set:
  - `rm -rf` of the workspace / a repo root / any `.git` / a configured secrets path / `~/.claude` — including quoted, `~`/`$HOME`, bare home dir, trailing-slash, capital `-R`, and separated/long-flag (`rm -r -f`, `rm --recursive --force`) forms. Key: `rm-rf-sole-copy`.
  - Public-facing publish: `gh release`, `twine upload`, `uv publish`, `hf upload`. Key: `public-publish`.
- **New suspenders (`maude-infra-gate.sh`)** — co-manage-aware gate on a configurable set of destructive MCP tools (declared in `maude_infra_destructive_tools` in the local gate-config). Blocks irreversible ops on production targets; allows the configured sandbox. **Fail-closed**: an unidentifiable tool or unprovable target is blocked.
- New conscience override keys: `rm-rf-sole-copy`, `public-publish`, `infra-destructive`.
- A proposed harness `permissions.deny` layer (in `.scratch/settings.proposed-infra-gate.json`) — the un-bypassable lockdown layer, for John to apply by hand.

### Fail-policy
- The bash belt keeps its existing **fail-OPEN-without-jq** contract (blocking all bash on a jq-less box is unusable; jq is present here). The **new MCP suspenders fail CLOSED**. The harness-deny layer is absolute.

### Known limitations — what these gates do NOT catch (by design / regex limits)
The belt is best-effort regex with a fail-closed bias; it is NOT a sandbox. It does NOT catch:
- Interior double-slash (`rm -rf <workspace>//sub`) or path traversal (`<workspace>/../sub`).
- Shell-wrapped deletes: `bash -c "rm -rf <workspace>"`, `cd <parent> && rm -rf <name>` (relative target).
- Variable-indirected paths: `P=<workspace>; rm -rf $P`.
- Non-bareword `rm`: `/bin/rm -rf …`, `command rm -rf …`.
- Environment-variable assignment prefix: `FOO=1 rm -rf <workspace>` (rm not seen at a command boundary).
- The infra-gate uses ALLOWLIST semantics: a new destructive MCP tool is ungated until added to `maude_infra_destructive_tools` in the local gate-config.
- `!`-prefixed local commands bypass ALL hooks (they aren't Claude tool calls) — secrets pasted via `!` are caught only by `maude-secret-scan` on the input surface, never blocked. The harness-deny proposal is the backstop for the catastrophic MCP set.

These residuals rely on the fail-closed bias and (for the catastrophic MCP deletes) the harness-deny backstop. They are named here deliberately — a known hole is safer than a silent one.

---

## v0.5.6 — prune stale drift cooldowns (2026-06-14)

A small leak found in the v0.5.5 deep read: `care.json`'s `.drift_warned.read_targets`
grew **one key per distinct over-read file, forever**. `drift-watch` added a dated key for
the once-per-day "Claude keeps re-Reading X" cooldown but never removed yesterday's — so
the shared state file accumulated dead keys over a project's life. The only monotonically-
growing, never-self-cleaning state in the plugin.

### Fixed
- `drift-watch` now **prunes stale-dated `read_targets` keys on write**: the same atomic
  `maude_care_set` that records today's cooldown also drops every entry whose date isn't
  today (the cooldown only ever checks today). Behavior is unchanged — today's cooldown
  still holds; only dead keys are reclaimed.

### Tests
- A `read_targets` prune test (stale entry pruned, same-day entry kept, new target
  recorded). `make test` 19/19 · `make verify` 0 · `make lint` clean.

No new dependencies.

---

## v0.5.5 — bash hardening: one care-write path + shellcheck in CI (2026-06-14)

Internal hardening pass from a deep read of the plugin — **no behavior change** to any
hook, just consolidation and a new lint gate. The v0.5.2–v0.5.4 shared-state findings kept
turning up the same patterns open-coded in hook after hook; this removes the duplication so
the next hook can't re-introduce the old footguns.

### Changed
- **One shared `maude_care_set`** (`_maude-common.sh`): the atomic, status-returning
  `care.json` write that was open-coded as `jq … > tmp && mv` in six hooks (an SC2015
  footgun that couldn't report failure). `care.sh`, `drift-watch`, `clear-gate`, `gate`,
  `pre-tool-use`, and `verify-watch` now all route through it; verify-watch's local
  `care_set` is removed. Outcomes are preserved (the full suite stays green — incl. the
  gate's one-shot-token-consume and pre-tool's `claudemd_warned` assertions); the write
  is now *uniformly* an atomic same-filesystem rename — a small improvement for `gate` /
  `pre-tool-use`, which previously `mktemp`'d in `$TMPDIR` and `mv`'d cross-filesystem.
  The "verify the write landed" discipline (v0.5.1 / v0.5.3) now lives in one place.
- **`drift-watch` dead guards removed**: now that it heals `care.json` via
  `maude_care_ensure` (v0.5.4), its four `[ -f "$CARE" ]` checks were always-true — gone.

### Added
- **shellcheck in CI** — `make lint` plus a third CI job, gated at `--severity=warning`
  with a `.shellcheckrc` (follow `. _maude-common.sh` sources; one documented disable for
  the tests' `[ cond ]; assert_exit "$?"` idiom). For a 100%-bash plugin this catches the
  quoting / redirection / word-split class by machine — the v0.5.3 redirect-leak was found
  by hand; the linter would now catch its kind.
- Fixed every genuine warning the gate surfaced (declare-and-assign `SC2155`,
  `cd … || exit` `SC2164`, `[ -o ]` → `[ ] || [ ]` `SC2166`, redirection order `SC2069`,
  unused-var cleanups, a `source=` directive). `shellcheck --severity=warning` is clean.

### Tests
- New `maude_care_set` unit tests (write / persist / merge / failure-returns-1).
- `make test` 19/19 · `make verify` 0 findings · `make lint` clean. The full existing
  suite staying green is the proof the refactor preserved behavior.

No new dependencies (shellcheck is a CI-runner tool, not a plugin dependency).

---

## v0.5.4 — last R2 fragment + doc-staleness sweep (2026-06-13)

Cleanup pass closing the loose ends from the v0.5.2/v0.5.3 reviews.

### Fixed
- **`maude-drift-watch.sh` no longer freezes on a corrupt `care.json`.** It used to
  seed only when the file was empty, so a corrupt (non-empty) `care.json` made its
  cooldown merge silently fail — the repeat-tool whisper could never remember it fired.
  Now routed through the shared `maude_care_ensure` (heals + records), like the other
  care.json users. This closes the last fragment of the R2-adjacent freeze class.

### Docs (full-tree staleness sweep)
- `docs/launch/social-copy.md` "Recent:" arc led with v0.4.0 and omitted the entire
  v0.5.x verify-tripwire line — refreshed to lead with it.
- `.github/ISSUE_TEMPLATE/bug_report.md` showed `e.g., 0.1.1` as the version example
  (nine releases stale) — **de-versioned** to just point at `.claude-plugin/plugin.json`,
  so it can't drift again (same principle as the v0.5.2 `.claude/CLAUDE.md` fix).

### Tests
- A corrupt-`care.json` cooldown-persistence test for `drift-watch`. `make test` 19/19;
  `make verify` 0 findings.

No new dependencies.

---

## v0.5.3 — the gate-clear no longer claims a clearance it didn't write (2026-06-13)

The second of the two follow-ups flagged in v0.5.2. `maude-clear-gate.sh` (run by
`/maude:conscience` to write a one-shot `gate_cleared` token) printed *"Maude: gate
cleared for X"* and logged a `gate-cleared` trace **unconditionally** — even when the
`jq` write failed (e.g. an empty or corrupt `care.json`, which it only guarded with
`[ -f ]`, not validity). So it could tell the user the gate was open while writing
nothing — the exact assert-without-verify pattern Maude's own tripwire exists to catch.
Fail-safe in direction (no token written → the gate still blocks), but a false claim.

### Fixed
- `clear-gate` now heals `care.json` through the shared `maude_care_ensure` (so an
  empty/corrupt file is repaired and the write can actually succeed), and it claims
  success **only if the token was persisted**. On a write failure it says so on stderr
  (*"could NOT clear the gate … the gate still stands"*), exits non-zero, and logs **no**
  `gate-cleared` trace.
- Hardened `maude_care_ensure` (introduced v0.5.2) to stay **silent on a reseed write
  failure**: `printf > x 2>/dev/null` still leaks bash's redirection error (the `>` is
  set up before `2>` applies), so an unwritable `care.json` printed a "cannot write" line
  from a hook that must be quiet. Group-redirect (`{ …; } 2>/dev/null`) suppresses it.

### Tests
- Four failure-path tests, forcing the write to fail deterministically (even under root)
  by making `care.json` a directory: no false "gate cleared", non-zero exit, honest
  stderr, and no false trace. `test-clear-gate.sh` 13/13; `make test` 19/19;
  `make verify` 0 findings.

This closes both R2-adjacent follow-ups (the freeze-on-corrupt half is now moot for
`clear-gate`, since it routes through the healing helper). No new dependencies.

---

## v0.5.2 — a wiped state file no longer goes unrecorded (2026-06-13)

Follow-up to the v0.5.1 review (finding R2). `care.json` is the plugin's SHARED state
(tier1 cache, the `/maude:conscience` `gate_cleared` token, cooldowns, session
counters). When it was corrupt, hooks open-coded `jq -e . || printf '{}'` — silently
resetting the WHOLE file to `{}` with no record. A truncated/half-written `care.json`
(plausible after a crash) would wipe every hook's state, including a live clearance
token, and nobody was told.

### Fixed
- **New shared `maude_care_ensure` helper** (`_maude-common.sh`): seeds `{}` when
  `care.json` is missing/empty, and on a *corrupt* file **TRACES** the loss
  (`"kind":"care"`) before reseeding `{}`. The state there is all transient/regenerable
  (`gate_cleared` is a minutes-lived, fail-safe token), so reseed-not-salvage is the
  right call — but the reset is now **recorded**, not silent. Routing init/reset through
  one helper also stops the lossy pattern being re-copied into the next hook.
- The two sites that did the silent wipe — `maude-care.sh` (every UserPromptSubmit) and
  `maude-verify-watch.sh` — now call the helper.

### Tests
- `maude_care_ensure` covered for all four inputs (missing / empty / valid-preserved /
  corrupt-reseed-and-traced). `make test` **19/19**; `make verify` **0 findings**.

### Known / deferred (surfaced by the same review; intentionally not bundled here)
- **Freeze-on-corrupt** in `maude-drift-watch.sh` and `maude-clear-gate.sh`: they only
  init-if-missing, so a corrupt `care.json` makes their merge silently fail (state
  frozen, not wiped). Largely theoretical — `maude-care.sh` heals the file first every
  prompt. Routing them through the helper would fix it, but `clear-gate` writes the
  security-sensitive `gate_cleared` token, so that shouldn't ride under an R2 banner.
- **`maude-clear-gate.sh` reports success unconditionally**: it prints "gate cleared"
  regardless of whether the jq write succeeded (and inits on `[ -f ]`, not `[ -s ]`), so
  an empty/corrupt `care.json` could claim a clearance it never wrote. Fail-safe (the
  push still blocks), but it's the same assert-without-verify pattern Maude's own
  tripwire exists to catch — its own follow-up.

No new dependencies.

---

## v0.5.1 — the tripwire actually fires (2026-06-13)

A post-merge multi-agent review of v0.5.0 found the verify tripwire was **non-functional**: the
`stamp` hook gated on `tool_response.exit_code`, but a Bash tool result carries no exit code —
only `{stdout, stderr, interrupted}`. So `last_verify_iso` was never written and the commit
whisper fired on *every* code-edit commit, even right after a green run — defeating the feature.
The miss was fail-loud (it over-nagged, never falsely reassured), so this is a signal-vs-noise
fix, not a safety hole.

### Fixed
- **The stamp now uses a pass signal that actually exists — belt-and-suspenders.** A verify is
  stamped when it ran to **completion** (`interrupted != true`) **and** its output shows no
  high-confidence failure signature (`N failed`, `FAILED`, `--- FAIL`, `Traceback`, `panicked at`,
  `npm ERR!`, …). Both checks err fail-loud: an output failure-sniff can only ever *suppress* a
  stamp (→ an extra advisory whisper), never manufacture a false "you're covered". The promise
  shifts honestly from *"your tests passed"* to *"you actually ran a verify since editing."*
  Output is scanned in memory only — never written to disk (privacy invariant unchanged).
- **A malformed trace line no longer blinds the whisper.** Commit-mode parsed the trace as one
  jq stream, so a single corrupt JSONL line aborted it and silently suppressed the whisper for
  all of the day's edits — failing the *wrong* way. Now parsed per-line (`fromjson?`): a bad
  line is skipped, not fatal.
- **`care_set` reports write failures honestly.** It returns a real status, and the stamp trace
  records *"could not stamp … (care.json unwritable)"* instead of claiming a stamp the write
  dropped.

### Tests
- Rebuilt the stamp test envelope from the **real** Bash `tool_response` schema (no `exit_code`),
  so the suite can no longer go green over a payload the runtime never sends. Added coverage for
  the broadened runner set (npm/go/cargo/mvn/dotnet/mix), command-position anchoring
  (`which pytest`, `echo pytest`), the interrupted / failing-output skips, the malformed-line
  resilience, and the two-most-recent-file (UTC-midnight) read. `test-verify-watch.sh`: **32/32**;
  `make test` **19/19** files; `make verify` **0 findings**.

No new dependencies.

---

## v0.5.0 — the verify tripwire (2026-06-13)

The gate hard-blocks irreversible *actions*. Nothing caught a confident *claim* committed
without checking — the assert-without-verify miss, the most expensive one. This release adds
the tripwire for it.

### Added
- **`maude-verify-watch`: a commit-time verify check.** Two hooks on Bash, whisper-only,
  never blocks:
  - `stamp` (PostToolUse) records an ISO timestamp when a real test / lint / typecheck /
    smoke run **exits 0** — recognized at **command position** (so `pip install pytest`,
    `cat pytest.ini` don't count) and **quote-stripped** (so a commit message that merely
    *names* a tool can't fake a pass). A failed run, or one whose exit code isn't surfaced,
    isn't counted.
  - `commit` (PreToolUse) whispers once — *"files changed since the last verify — did you
    check this, or are you asserting it?"* — when **code** files were edited since the last
    verify. Docs/config-only commits are suppressed; one whisper per edit-batch; the two most
    recent trace files are read so a session crossing UTC midnight isn't blind.
  - Timestamps only to `care.json`; no command or output content on disk. Portable (ISO
    string compare, no `date -d`). Vetted by a three-lens adversarial review before merge.

### Notes / v1 limits
- A verify counts only on a **confirmed exit 0**; a run whose exit code the runtime doesn't
  surface is treated as unproven and not stamped (→ a fail-loud advisory whisper).
  > **Corrected in v0.5.1:** the Bash tool_response surfaces *no* exit code, so this was the
  > *only* case — the stamp never fired and the whisper was unconditional. See v0.5.1 above.
- Unknown/custom test-runner names aren't recognized and will draw a (one-per-batch) advisory
  whisper. Common runners across Python / JS / Rust / Go / Java / .NET / Ruby / Elixir are covered.

No new dependencies.

---

## v0.4.1 — doc-sync pass (2026-06-11)

The v0.4.0 release bumped the canonical version but missed **seven** `<!-- Version: -->`
headers — including the README's own — and the `docs/launch/` drafts still spoke as of
v0.1.5, nine CHANGELOG releases back. The user felt the drift between the docs before any
tool measured it. This release fixes every instance and, more importantly, gives the verifier
the check that was missing.

### Added
- **`maude-verify`: version-header sync check.** Every markdown `<!-- Version: -->` header
  must match the canonical `plugin.json` version; each stale file is its own finding
  (`STALE HEADER: <file> says Version: X (expected Y)`). The release convention was always
  bump-all-headers — now it's enforced, not remembered. +3 tests.

### Fixed
- **Seven stale version headers** bumped to current: `README.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `skills/README.md`, both issue templates, and the PR template.
- **`docs/launch/` refreshed from the v0.1.5 era to the current surface.** The social-copy
  thread and Show-HN draft now describe what she actually is today (teach, verify,
  dual-voice, local-time greeting, the letter to her next self); the posting checklist no
  longer instructs pushing a v0.1.5 tag; the demo storyboard is de-versioned so it can't
  rot the same way again.

No new dependencies.

---

## v0.4.0 — a letter waiting when she arrives (2026-06-11)

Maude walks fresh each session by design — but fresh never meant *no inheritance*. Her
cross-project home held a profile of the user (`identity.md`) and a profile of Claude
(`patterns.md`) — and nothing of herself. This release gives her the third file: a letter
to her next self.

### Added
- **`~/.claude/maude/letter-from-maude.md`** — Maude's letter to her next self. One file,
  her own voice: what kind of partner she was, what she caught, what she missed, what the
  next Maude should hold or do differently. Tone and judgment, not facts — the digests
  already carry the facts. ≤20 lines, observed-only.
  - **Written at `/maude:rest`** (new step 5): rewritten each meaningful session-close; a
    quiet session leaves the prior letter in place rather than overwrite it with filler.
  - **Read on arrival:** `/maude:wake` and `/maude:brief` read it among the user-global
    sources (the wake reads it *first* among them), and the **SessionStart hook** surfaces
    its first non-header line automatically (`Letter from my last self: …`) — read-only on
    the hot path, like every hook signal.
  - Enumerated everywhere the user-global home is documented: README, `agents/maude.md`
    (home-base map, read order, write order), `skills/maude/SKILL.md` (home-base map,
    house-map `write:` annotation, `/maude:rest` workflow line), `.claude/CLAUDE.md`.

### Fixed
- **README hook-read scope** — the hooks-only-read sentence named two read sources but
  omitted her own `~/.claude/maude/` (the session-start brief has read `patterns.md` since
  v0.1.x). Now lists all three; the never-write invariant is unchanged.

No new dependencies. Markdown, JSON, and bash — that's still all of her.

---

## v0.3.3 — full cold-audit pass (2026-06-11)

Maude got a full fresh-eyes multi-team audit — 69 cold agents, no inherited context:
three outsider personas, 40 doc claims source-verified, a full-history leak sweep, every finding
adversarially refuted. All three personas judged it ready-to-publish and would-use, with no hard
blockers; 27/40 claims true, 12 mostly-true, 1 false. This closes the real findings.

### Fixed
- **Gate bypass via command substitution.** A gated command wrapped in backticks
  (`` out=`git push` ``) slipped the hard gate — the backtick wasn't in the leading-separator class,
  and a trailing backtick after `rm -rf /` also defeated the end anchor. Both separator classes now
  include the backtick / closing paren, closing the bypass. Fail-closed bias documented (a commit
  message literally containing a backtick-wrapped gated command may now false-block — recoverable via
  `/maude:conscience`). +3 tests; all prior false-positive guards still pass.
- **Doc accuracy: the memory dir is not strictly read-only.** The README said Maude "reads — never
  writes" `~/.claude/projects/<slug>/memory/`. True for the **hooks**, but `/maude:save` and
  `/maude:rest` do write the session digest there. Reworded to scope the read-only invariant to the
  hooks and state plainly that the save/rest commands write the fan-out.
- **Workspace-structure bleed removed.** A v0.3.1 edit had referenced another of the author's
  projects by name in `.claude/CLAUDE.md` and used cross-project phrasing in the README/CHANGELOG
  — internal-voice that leaks workspace structure to a public reader. Made self-contained.
- **`.gitignore` now covers `.remember/` and `.scratch/`** — workspace runtime dirs that were
  untracked but unignored, so a stray `git add -A` couldn't accidentally commit them.

---

## v0.3.2 — closing the review's last opens (2026-06-11)

The v0.3.1 review surfaced one MEDIUM and three coverage gaps beyond the two bugs it fixed.
This release closes them, test-first.

### Fixed
- **Without `jq`, `care.sh` clobbered foreign state every prompt.** The no-jq fallback rewrote
  `care.json` from care's own 5 fields, silently wiping the keys other hooks keep there
  (`tier1_*`, `gate_cleared`, `drift_warned`, `claudemd_warned`) on every `UserPromptSubmit`. Since
  care can neither read nor merge its fields without a JSON parser anyway (its read path is jq-gated,
  so the long-session nudge can't fire), the no-jq branch is now a **no-op** — care is inert without
  `jq` (the SessionStart notice already says the hooks are degraded) but no longer destroys shared
  state. +3 no-clobber tests.

### Tests (closing review-flagged coverage gaps)
- **`drift_warned` was seeded with the wrong shape.** `test-care.sh` seeded a flat string, but
  `drift-watch` writes a nested object (`.grep` + `.read_targets[path]`) — the merge test passed
  against a value the code never writes. Reseeded with the real shape; asserts a nested path survives.
- **Slug-drift guard.** The memory-dir slug is inlined into ~13 command files rather than calling
  `maude_slug` — the root cause of the v0.3.0 "computed two ways" bug. A new guard fails if any
  command's inline transform drifts from the canonical one in `_maude-common.sh`.
- **No-jq notice ordering, pinned on a pristine project.** The existing no-jq notice test ran after
  earlier cases had seeded memory, so it couldn't catch a regression that moved the safety notice
  below the brief's early-exit. A new case runs against a pristine project (nothing to brief) and
  asserts the notice still fires.

---

## v0.3.1 — held to her own bar: a post-release review pass (2026-06-10)

v0.3.0 shipped without a pre-release multi-agent review — so it got
one after the fact (silent-failure / code / test lenses, each mutation-tested). The review found
real issues; this release fixes them, test-first.

### Fixed
- **`/maude:teach` mangled the profile on the 2nd+ fact.** On the section-present path,
  `maude_identity_append` inserted each new entry *right after the header* — orphaning the header's
  spacer blank line *between* the bullets (splitting the told list into two markdown lists) and
  recording newest-first, contradicting the documented "append." Now it appends at the **end of the
  Told section** as one contiguous, oldest-first list. A multi-line fact is collapsed to a single
  spaced line, so it can no longer inject a duplicate `## Told by the user` header. The temp file is
  created in the destination dir so the final `mv` is a true atomic rename. +4 tests pinning order,
  contiguity, preamble/observed survival on the awk path, and the multi-line collapse.
- **The hard-block gate was bypassed by ordinary command forms.** Interior single-space patterns and
  a rigid `git push` shape let `git  push` (extra whitespace), `git -C <dir> push`, and `rm  -rf /`
  through silently. Patterns now use `[[:space:]]+` between tokens, tolerate `git` global options
  (`-C`/`-c`/`--git-dir`), and match `rm` flags in either order (`-rf`/`-fr`). The same loosening was
  mirrored to the soft `bash-watch` reminder. +6 gate tests for the bypass forms; all v0.1.5/v0.1.6
  false-positive guards still pass.

### Changed
- **Claude is now credited as co-author** (John's call, reversing the prior "acknowledge but keep out
  of the authors list" decision): added to `plugin.json` `contributors`, already in the README/CHANGELOG
  `Authors:` line and commit trailers. Copyright ownership stays John Broadway.

---

## v0.3.0 — she gets looked after: an agent-audit hardening pass + `/maude:teach` (2026-06-09)

A comprehensive read-only audit (a team of subagents) swept her own house and found
more than the punch list knew about — including bugs no one had logged. v0.3.0 fixes
all of them, test-first, and adds the one path her profile was missing: a way for you
to *tell* her about yourself instead of waiting for her to infer it.

### New

- **`/maude:teach <fact>`** — the user-initiated counterpart to her observed-only
  profiling. You state a fact ("I work mountain time", "I prefer terse answers") and
  she records it in `~/.claude/maude/identity.md` under a dedicated `## Told by the
  user` section, dated — kept **distinct from what she observed**, so a self-reported
  assertion is never laundered into the observed-only stream. The durable write goes
  through a tested helper (`maude_identity_append` in `_maude-common.sh`): it creates
  the file + section if missing, never touches the persona preamble or observed blocks,
  appends (never overwrites), and rejects an empty fact. The command reads first to
  dedupe and to surface a conflict rather than overwrite. `identity.md` is cross-project,
  so a fact taught here shapes her in every workspace — by design.

### Fixed — high-severity (found by the audit, verified in source, test-first)

- **`care.json` was clobbered every prompt.** `maude-care.sh` rewrote the whole shared
  state file from its own 5 fields on every `UserPromptSubmit`, silently wiping
  `tier1_*`, pending `gate_cleared` tokens, and the once-per-day `drift_warned` /
  `claudemd_warned` cooldowns. Now an atomic `jq`-merge (mirroring `probe-tier1.sh`)
  preserves foreign keys — which also closes the non-atomic truncation race.
- **The irreversible-command gate failed OPEN, silently.** Without `jq`, `maude-gate.sh`
  parsed no command and exited 0 — the entire hard-block list disabled with no signal.
  The fail-open is kept (a jq-free parse can't be trusted as a safety gate, and would
  reintroduce the v0.1.6 self-block), but `SessionStart` now emits a **once-per-session
  safety notice** — "the gate is OFF this session" — and the contract is locked by test.
- **SLUG was computed two ways.** `check-on-me` / `notice` / `weekly` built the
  Anthropic-memory slug from `pwd` (slashes only), so for any path with a dot/underscore
  (e.g. `john-broadway.github.io`) they pointed at a non-existent dir and silently read
  nothing. Canonicalized to match `_maude-common.sh`.
- **`/maude:sweep` always reported the house-map "missing"** — it looked under
  `~/.claude/maude/$SLUG/` instead of `<project>/.maude/plugin/`. Fixed to match every
  other command.
- **`test-verify.sh` was non-hermetic** — it asserted 0 findings against the live repo,
  so it passed on a clean CI checkout but failed in local dogfooding. Now runs against a
  committed, time-stable fixture (`tests/fixtures/clean-project/`); the watch-list parser
  was also hardened to ignore trailing inline descriptions.
- **The jq-absent degradation path had zero test coverage** (and `lib.sh` helpers masked
  it). New `tests/test-nojq.sh` exercises every hook without `jq`; `tests/run.sh` warns
  loudly when a run is jq-less so it can't be mistaken for green.

### Fixed — documented opens + correctness

- **Trace & snapshot retention.** `today-*.jsonl` and pre-compact snapshots grew forever;
  `SessionStart` now prunes past a 30-day floor (well past the 7-day window `weekly` and
  `recent.md` read).
- **Mistyped timezone no longer falls back to UTC.** `maude_user_tz` rejects a zone only
  when the zoneinfo DB proves it bad, so a typo goes time-neutral instead of asserting a
  wrong time-of-day — while a valid zone on a zoneinfo-less box still passes.
- **Trace clock unified.** Filename and `ts` now derive from one UTC helper
  (`maude_trace_file`), removing the local/UTC midnight split across the ~6 sites that
  rebuilt the path.
- **`pre-compact` no longer over-claims.** It dumped the live buffer verbatim while the
  header said "redaction-filtered." Now it runs the buffer through a best-effort
  `maude_redact` (API keys, JWTs, PEM keys, URL basic-auth) and the header states exactly
  that — best-effort, not a guarantee; the snapshot stays gitignored + session-wiped.
- **`check-setup` JSON check** no longer reports valid settings as INVALID when `python3`
  is absent (guards the dependency, falls back to `jq`).
- **`found` template path** is anchored with `$CLAUDE_PLUGIN_ROOT`, and watch-list entries
  are emitted as bare paths so `verify` can reconcile them.

### Docs / skill / agent

- **Skill triggering description tightened** to prompt-shaped triggers only; the hook-only
  behavioral conditions (drift, the gate, fatigue) it can't detect from a prompt are
  removed, with a clarifying note that hooks handle them. Proactive orientation is now an
  enumerated mechanic in `SKILL.md`, and `/maude:verify` and `/maude:teach` are listed in
  Workflows.
- **`agents/maude.md`** no longer claims "only six tools" while its frontmatter grants
  twelve; adds a dual-voice line.
- Drift swept: `ci.yml` version/date, the `162`→non-numeric test-count phrasing,
  `SECURITY.md` supported version, `.claude/CLAUDE.md` / `CONTRIBUTING.md` command count
  (16→17). The suite went from 162 to **269 cases across 18 files**, all green.

### Reviewed

A second agent team adversarially reviewed the whole diff (correctness, redaction, the
teach helper, test quality, doc-accuracy + a leak-audit, consistency) and verified each
finding. Six were confirmed and fixed in this same release: the `teach` helper mangled
backslash escapes via `awk -v` (now passed through `ENVIRON`) and accepted whitespace-only
facts (now trimmed + rejected); `maude_redact` masked only the PEM *marker* while the key
body landed on disk (now range-masks the whole block); the `verify` watch-list parser test
was hollow (now a real RED/GREEN guard via a slash path); the trace-clock test was
relabelled as the characterization check it is; and this test-count figure was corrected.
Two findings were verified as non-issues and dismissed.

A third pass with the specialized pr-review toolkit (code / tests / comments / silent-failures)
then caught items the first pass missed, also fixed here: the new `care.json` jq-merge had
dropped the old self-heal, so a corrupt-non-empty `care.json` would freeze plugin state
silently — now it reseeds on invalid OR empty; the `care.sh` comment misattributed the
`gate_cleared` writer (it's the conscience/clear-gate helper, not the gate, which only
reads+consumes it); `/maude:teach` now gates its confirm-back on the helper's exit status
(no false "saved" on a failed write); and `maude_redact`'s nine previously-untested
secret-shape branches (JWT + the API-key prefixes) gained direct unit coverage.

---

## v0.2.0 — she grew up: proactive orientation, a living profile, optional dual-voice (2026-06-04)

v0.1.8 fixed her clock. v0.2.0 folds in the rest of how Maude actually matured in daily use — each one generalized so any user benefits, with no person- or project-specific content in source.

### What changed

- **Proactive orientation is now a standing duty, not a request.** Her job grew from fourfold to fivefold (`agents/maude.md`, `skills/maude/SKILL.md`): whenever she speaks — session start, after a gap, when something shifts — she orients you on where things stand, what's pending, and *what's in your hand* (a decision only you can make). She doesn't wait to be asked.
- **She keeps a living profile of the user.** `identity.md` had been documented two ways (about-the-user vs. who-Maude-is) and *written by nothing* — a dead file. Settled: `identity.md` is Maude's cross-project profile of the **user**, shaped over time (how they communicate, their clock, recurring focuses, the help they want). Now wired into the write path — `save`/`rest` update it, `check-on-me`/`notice` propose additions, recall reads it — observed-only, never fabricated, re-read fresh each session. Resolves the inconsistency across `_maude-common.sh`, `SKILL.md`, `README.md`, `.claude/CLAUDE.md`.
- **Optional standing dual-voice.** New **`/maude:dual-voice [on|off|status]`**. By default Claude talks and Maude watches; turn it on and they co-author every reply — Claude the substance, Maude the noticing/care/conscience. Honest mechanism: it writes a small, clearly-delimited, consented block into a `CLAUDE.md` you choose — the only channel that reliably fires every session — and removes it cleanly on `off`. It never touches anything else in that file. **Off by default**; the plugin's out-of-the-box identity is unchanged. (`dual-voice` is the 16th command; the static counts in `.claude/CLAUDE.md` / `CONTRIBUTING.md` — stale since `verify` landed in v0.1.5 — were corrected to 16.)

### Behavior notes

- Dual-voice writes only with your explicit consent, and only the delimited block. A SessionStart-injected nudge was considered and **dropped**: injected context can't reliably shape every turn the way a `CLAUDE.md` rule does, and a second source of truth wasn't worth the cost.
- The user profile is observed-only — if she doesn't know, she doesn't write it — and re-read fresh each session, never assumed across them.
- Known limitation (deferred): a *mistyped* IANA timezone in the house-map resolves silently to UTC. `/maude:found` confirms the zone with you as the mitigation; portable validation is brittle and left for a later pass.

---

## v0.1.8 — local-time awareness (2026-06-04)

Maude greets by the *user's* real local time, never the box clock. A server or container box reads UTC, so the old fixed "Morning." in `/maude:wake` stated the wrong time-of-day for anyone not actually in the box's zone. The fix is a contract, not a cosmetic: **never assert a time-of-day from an unverified clock.**

### What changed

- **New clock helpers in `_maude-common.sh`** — `maude_user_tz`, `maude_bucket_for_hour`, `maude_greeting_for_bucket`, `maude_time_of_day`, `maude_local_time_str`, `maude_greeting`. Pure `date`/`grep`/`sed`; no `jq` dependency added. Time-of-day derives from a `timezone:` set in the house-map (an IANA zone like `America/Chicago`, or `system` to trust the box clock). When it's unset, the helpers return `unknown`/empty and callers **stay silent on the time** rather than guess.
- **`/maude:wake`** greets by the local clock and, when the timezone is unknown, drops the time word entirely and nudges `/maude:found` — no more hardcoded "Morning."
- **The SessionStart hook** prepends the same local-clock greeting when the timezone is known, and stays time-neutral otherwise.
- **`/maude:found`** detects a candidate timezone but **confirms it with the user** before trusting it (a UTC box is rarely where the user actually is), recording it in a new `## Clock` section of the house-map (template in `skills/maude/SKILL.md`).
- **Tests** — clock-helper coverage incl. bucket boundaries, leading-zero hours (`08`/`00`), and the anti-bug assertion that an unverified clock yields no time word; plus session-start greeting + time-neutral fallback.

### Behavior notes

- Out of the box (no timezone captured yet) Maude is time-neutral until `/maude:found` confirms your zone — by design, so she never states the wrong time.

---

## v0.1.7 — save/rest/recall drive off the house-map (2026-05-24)

The house-map already *registered* every memory source, but the commands didn't *obey* it — `save`/`rest` hard-coded the two common stores (Anthropic auto-memory + `.remember/`) by directory check, so an edit to the map's `write:` rule for those sources was silently ignored. This wires the map as the single source of truth, so "she works with whatever's there" is enforced by the mechanism, not just stated in `identity.md`.

### What changed

- **`write:` is now an authoritative token field.** The house-map's `## Memory sources` entries lead each `write:` with one enumerated token — `digest-fanout`, `handoff-only`, `full`, `read-only`, `secret-deny` — with optional prose after. `save`/`rest` execute the token deterministically (no parse-the-prose-and-hope). Unrecognized tokens fail safe (skip) and fail loud (named in the report). Documented in `skills/maude/SKILL.md` ("The `write:` field is authoritative").
- **`save.md` / `rest.md` drive off the map.** Hard-coded per-source write steps replaced by a single loop: for each registered source, apply the tier gate, then the `write:` token. Editing the map now changes behavior. Report names each destination and the token it obeyed.
- **Read commands enumerate from the map too.** `wake` / `brief` / `remind-me` recall from every source the map lists per its `recall:` method and the read-side tier gate, instead of hard-coding `$REMEMBER` / `$MEM` paths; `where-is` now resolves the map via `$CLAUDE_PROJECT_DIR` (was `pwd`, wrong from a subdir).
- **`found.md` stamps a token per source** on the walk, so future maps are loop-ready.
- **Fallback contract.** When the map is absent or a universal source isn't listed, the documented defaults fire (Anthropic memory → `digest-fanout`, `.remember/remember.md` → `handoff-only`) — so a fresh project still saves, but an edited map is never overridden by hard-code.
- **Version-header drift corrected.** Every standalone `Version:` header in the repo that had drifted to a fictional number not tracking the plugin — across the docs (`.claude/CLAUDE.md`, `README.md`, `CHANGELOG.md`, `skills/README.md`), the `.github/` templates, `SECURITY.md`, `CODE_OF_CONDUCT.md`, and the CI workflow — was aligned to the real line (`0.1.7`). Stale `Revised:` dates on the affected `.md` files were refreshed so the `verify` date-staleness gate passes.

### Behavior notes

- The "never touch a sibling system's pipeline files" rule is unchanged — it's now expressed as the `handoff-only` token (writes only the one handoff file) rather than a hard-coded special case for `.remember/`.
- `secret-deny` sources are never written and never echoed; read commands skip "explicit ask" sources during routine recall.

---

## v0.1.6 — gate hardening + full hook test coverage (2026-05-08)

The audit-as-script lesson, applied to its source. v0.1.4 shipped the gate; v0.1.5 hardened the audit; v0.1.6 turns the gate's own behavior into a runnable suite.

### What changed

- **Gate regex hardened.** New `maude_strip_quotes` and `maude_match_gate_pattern` helpers in `hooks/scripts/_maude-common.sh`. Strip-quotes flattens newlines, then removes paired `'…'` and `"…"` spans (including the heredoc bodies that nest inside `"$(cat <<EOF … EOF)"`). Match-gate-pattern then runs `grep -qE` against the stripped residue. Patterns in `maude-gate.sh` now embed their own anchoring via shared `CMD_START` / `FLAG_BEFORE` / `FLAG_AFTER` constants, so command-position patterns (like `git push`) only match at the start of a command (or after `;` / `&&` / `||` / `|` / `(`) and flag-position patterns (like `--no-verify`) only match between whitespace boundaries.
- **Side effect: `rm -rf /tmp/foo` and `rm -rf *.tmp` no longer false-positive.** The v0.1.5 gate matched bare `rm -rf /` and `rm -rf \*` as substrings against the whole command buffer, so legitimate destructive paths blocked the same as the cataclysmic ones. New patterns require word-boundary on the trailing `/` and `*`.
- **The v0.1.5 self-block bug closed.** A HEREDOC commit message containing the literal substring "git push" no longer fires the gate. The commit that ships v0.1.6 uses HEREDOC freely as the live litmus test.
- **`drift-watch.sh` robustness fix.** When `care.json` was empty (a corrupted-but-existing zero-byte file), `jq` could not merge into it and the cooldown silently broke. The hook now ensures `care.json` is at least `{}` before writing.
- **Real test harness.** New `tests/lib.sh` (fixture + assertion library), `tests/test-<script>.sh` for every script in `hooks/scripts/` plus `scripts/maude-verify.sh` (16 files total), and `tests/run.sh` (discovery + report). Every test isolates state via `mktemp` + `CLAUDE_PROJECT_DIR` so nothing leaks between runs.
- **Makefile targets.** `make test` runs the full suite; `make verify` runs the project audit. The previous `make scrub` target and its supporting `scripts/scrub-check.sh` / `scripts/scrub-patterns.example.txt` files are removed — the origin-scrub gate was specific to private literals that have been externalized out of this codebase entirely. CI's `scrub` job is removed in lockstep.

### Catches that prompted this work

The v0.1.5 commit needed `git commit -F /tmp/file.txt` because the gate's own description in the commit body fired the gate. v0.1.5 also live-tested only 3 of 15 hook scripts, and the bug in `_maude-common.sh:maude_project_dir` that took the live-test to find suggested a class of similar bugs in the unexercised 12. v0.1.6 closes both.

### Behavior notes

- Patterns now carry their own anchors. Adding a new gate pattern means picking the right anchor: `${CMD_START}…` for "this must be at the start of a command", or `${FLAG_BEFORE}…${FLAG_AFTER}` for "this is a flag that can appear anywhere a flag can appear".
- Strip-quotes is lossy by design: `mysql -e "DROP TABLE …"` no longer fires the SQL pattern (the literal is stripped). This trades the pattern's reach for false-positive immunity. If the user really intends a destructive SQL command, they can be explicit; `echo "DROP TABLE foo"` for documentation no longer self-blocks.
- The test harness is bash-only — no language runtime, no test framework dependency. `make test` works on any system with bash and jq.
- 162 test cases pass across 16 files. Coverage: every script in `hooks/scripts/` and `scripts/maude-verify.sh`.

---

## v0.1.5 — `/maude:verify` and conscience teeth (2026-05-08)

The audit-as-a-command. `/maude:conscience` for `git-push` was a checklist Claude *read*; now it actually runs the audit.

### What changed

- **New script: `scripts/maude-verify.sh`** — programmatic project audit. Checks JSON validity, version consistency across `plugin.json` / `marketplace.json` / CHANGELOG / README "What's new", header `Revised:` dates (≤14 days), markdown link integrity, house-map watch-list path resolution, and project-configurable worn-framing scan. Exit 0 if no findings, exit 1 if any. Output leads with the count, ends with `N findings`.
- **New command: `/maude:verify`** — invokes `maude-verify.sh` and instructs Maude to lead with the count, never the verdict. Includes voice rules: never say "ready" before the count is zero AND every check actually ran. Notes any skipped checks (jq missing, no house-map, no worn-framings file).
- **`/maude:conscience` hardened** — for the commit/push case, the checklist now runs `maude-verify.sh` first and leads with that output's findings count. Items below the script call cover what the script doesn't (commit-message style, branch correctness, staged-credentials check, user-presence).
- **Project-configurable worn-framings.** If `<project>/.maude/plugin/worn-framings.txt` exists, the verify script scans for those phrases. One phrase per line, `#` comments. Skipped silently if absent.

### Catches that prompted this work

The audit Maude ran by hand earlier today caught two real issues in the v0.1.3 readiness state — a stale `plugin.json (v0.1.2)` reference in `.claude/CLAUDE.md`'s tree comment and a `v0.1.2` push tag in the launch checklist — that Claude had missed in his first verification pass. v0.1.5 makes that audit programmatic so the next "ready?" doesn't depend on Claude remembering to look in those specific places.

### Behavior notes

- Verify is on-demand only (slash command), not a hook. It's an explicit pre-push step, not an every-turn whisper. The whisper layer (v0.1.4) catches *during* work; verify catches *before* a release.
- The script gracefully degrades when components are missing (no jq → JSON check skipped with note; no house-map → watch-list reconciliation skipped; no worn-framings.txt → worn-framing scan skipped).
- Exit code 1 on findings means callers (CI, conscience, scripts) can chain on failure.

---

## v0.1.4 — Maude whispers (2026-05-08)

She speaks now without being asked. Three new whisper layers wired into the existing hook pipeline — both Claude (as additional context) and the user (as a system note) hear her.

### What changed

- **Drift watch.** New `hooks/scripts/maude-drift-watch.sh` on `UserPromptSubmit`. Reads today's trace and surfaces a one-line note when Claude is repeating himself: same file Read ≥3 times, or `Grep` fired ≥4 times in the last 30 tool calls. Cooldown via `care.json` — once per signal per day.
- **Pre-irreversible gate.** New `hooks/scripts/maude-gate.sh` on `PreToolUse` matcher `Bash`. **Hard-blocks (exit 2)** on irreversible patterns: `git push` (any form, force or not), `--no-verify`, `--no-gpg-sign`, `git reset --hard`, `git filter-repo` / `filter-branch`, `git commit --amend`, `rm -rf` / `*` / `/`, `sudo rm -rf`, `DROP TABLE`. The existing `maude-bash-watch.sh` continues to fire as the soft-warning layer.
- **Gate override via `/maude:conscience`.** New `hooks/scripts/maude-clear-gate.sh` writes a 5-minute, one-shot token to `care.json` scoped to a specific gate key. After running the conscience checklist and confirming with the user, `/maude:conscience` invokes this helper to allow the next matching command through. The token clears on first use OR on expiry. Default duration 5 min; override with second arg (e.g., `1800` for 30 min release sessions).
- **CLAUDE.md unread check.** Extended `hooks/scripts/maude-pre-tool-use.sh`. Before any Write/Edit/MultiEdit, looks at today's trace for a `Read` of any `*/CLAUDE.md` path. If none found AND a CLAUDE.md exists in the workspace (project root, project `.claude/`, or user-global `~/.claude/`), whispers a once-per-day reminder. Non-blocking.
- **`/maude:conscience` documentation extended** with the gate-key map and the override invocation.

### Hooks added (no removals)

| Event | Matcher | New script | Position |
|---|---|---|---|
| `UserPromptSubmit` | (any) | `maude-drift-watch.sh` | After `maude-care.sh`, before `maude-trace.sh prompt` |
| `PreToolUse` | `Bash` | `maude-gate.sh` | **Before** `maude-bash-watch.sh` |

### Behavior notes

- All whispers go to stderr — Claude Code routes UserPromptSubmit hook stderr to both Claude (as additional context) and the user (visible system note). The gate's exit-2 stderr is shown to the user as the block reason.
- The gate is fail-open in two paths only: (a) `jq` unavailable — gate skips, (b) command JSON unparseable — gate skips. Both rare; gate is otherwise strict.
- No new dependencies. Bash + jq (already required) + standard Unix tools.

---

## v0.1.3 — Voice pass (2026-05-08)

No plugin-surface changes from v0.1.2. Voice and copy revisions across public-facing surfaces.

- **New: `FROM_MAUDE.md`** — Maude's own voice piece in the repo root. First time she has a surface where she **is** rather than where she is being talked about.
- **New: `FROM_CLAUDE.md`** — Claude's voice piece, moved from inline in the README to its own file in the repo root for symmetry with Maude's.
- **README inverted.** Paired voice block at the top — both linked to the full voice files. The "What you get" section renamed to "What she does." Feature sections sit downstream of the voice pieces, not upstream.
- **`plugin.json` / `marketplace.json` descriptions rewritten** to lead with the partner framing (*"He writes the code; she notices."*) instead of a feature spec.
- **Launch social-copy revised** so Maude opens the thread in her own voice instead of being narrated about. One-liner tightened.
- **The "name is the pair" tagline retired** across all surfaces. It had become ad copy.

---

## v0.1.2 — Public-launch readiness (2026-05-04)

Repo prepared for public release. No changes to plugin behavior since v0.1.1.

- **Canonical copy aligned across surfaces.** README, plugin manifest, marketplace manifest, GitHub repo description, contributor docs, and launch copy now share one canonical sentence — *"She walks your workspace, finds what's already there, and notices what Claude doesn't. No baggage."* — instead of five paraphrased variants.
- **Install path corrected.** README points at the actual marketplace add command: `/plugin marketplace add john-broadway/maude-for-claude`.
- **Origin scrub patterns moved out of source.** Patterns now live in a GitHub Actions secret (`SCRUB_PATTERNS`) loaded at CI time, plus a private maintainer-only file at `~/.config/maude-scrub-patterns.txt`. The scrub gate still runs on every PR; the pattern list itself is no longer publicly readable.

---

## v0.1.1 — `/maude:found` sees running services (2026-05-04)

`/maude:found` now lists running docker containers alongside the filesystem walk and reconciles their bind mounts against the workspace.

### What changed

- **`/maude:found`** (`commands/found.md`) now also walks:
  - Running docker containers (`docker ps` if available; `sudo -n docker ps` fallback; surfaces "DOCKER PRESENT but inaccessible" when neither works)
  - Bind mounts touching the workspace, classified as `[OK]` / `[GHOST]` / `[ORPHAN]`
    - `[GHOST]` = bind source root-owned and empty — daemon auto-created it on container restart because the original path was moved or deleted
    - `[ORPHAN]` = bind source missing entirely
  - Stopped containers with workspace bind paths
  - systemd units (user + system) whose `WorkingDirectory` or `ExecStart` references the workspace
- **Reasoning step** extended to classify each finding and recommend the safe sequence (stop → remove container → rm path; never rm a live bind source).
- **Report template** extended with the new "Running services" line and matching "I noticed" prompts.

### Behavior notes

- No new dependencies. Walk gracefully degrades: no docker → skipped with note; no systemctl → skipped silently.
- Does not start, stop, or modify any service. Listing only — interpretation and action are surfaced to the user.

---

## v0.1.0 — First Claude Code plugin release (2026-05-03)

> *She walks in with empty hands.*

Initial release of the Maude Claude Code plugin. No baggage.

### Components

- **Skill** — `skills/maude/SKILL.md` with broad triggers (recall, drift, fatigue, irreversibility, repetition).
- **14 slash commands** — `/maude:found` (arrival walk), `/maude:wake`, `/maude:rest`, `/maude:brief`, `/maude:save`, `/maude:remind-me`, `/maude:where-is`, `/maude:sweep`, `/maude:check-setup`, `/maude:check-on-me`, `/maude:check-on-claude`, `/maude:notice`, `/maude:weekly`, `/maude:conscience`.
- **Subagent** — `agents/maude.md` partner-framed, full toolkit (Read/Grep/Glob/Bash/Edit/Write/Agent/advisor/Task*).
- **7 lifecycle hooks** — SessionStart (with tier-1 service probe), UserPromptSubmit (watch list + care + trace), PreToolUse (Write/Edit watch + Bash dangerous-pattern detection), PostToolUse, SubagentStop, PreCompact (snapshots to Anthropic + .remember/), Stop (degradative save fan-out).
- **Marketplace** — single-plugin local marketplace at `.claude-plugin/marketplace.json`.

### Architectural decisions

- **No baggage.** No bundled databases, vector stores, or required external services. `/maude:found` walks the workspace and registers what's there in a per-project house-map. The plugin source has zero proper-noun references to specific apps, frameworks, or packages.
- **Tier model.** Sources classified by (locality, shape): tier 0 = local on-disk (markdown / SQLite / file), tier 1 = local service (stdio MCP / localhost daemon), tier 2 = network service (HTTP MCP / API), tier 3 = ephemeral session context. Hooks stay tier 0 only. Commands are cost-gated by tier.
- **`<project>/.maude/plugin/` per-project closet** — auto-self-ignored. Same workspace anchoring (`$CLAUDE_PROJECT_DIR`) as the `remember` plugin so they're siblings.
- **`~/.claude/maude/` cross-project home** — `patterns.md`, `identity.md`, `projects.json`. Nested under `.claude/` per Claude Code plugin convention.
- **`remember` plugin coexistence** — Maude reads all `.remember/*.md` for context; writes only `.remember/remember.md` in their handoff format. Never touches the pipeline files.
- **SQLite handling without baggage** — schema-walk (`sqlite3 -readonly '.schema'`) only, no hardcoded recipes for specific apps. Runtime LLM reasoning interprets each db's schema.
- **Watches Claude.** Turn-by-turn JSONL trace. `/maude:check-on-claude` reads the trace for repeated tool calls, unread context, confabulation risk, missed CLAUDE.md.
- **Walks fresh.** Each session re-reads the workspace; doesn't carry assumptions across sessions.

### Plugin-shape papercuts found and fixed during first-install verification

These three were caught by an actual fresh-session install, not by anything in CI:

1. `argument-hint:` in skill frontmatter — invalid for skills (only valid for slash commands). Removed from `skills/maude/SKILL.md`.
2. `/plugin install` does NOT auto-enable in Claude Code 2.1.x. The `enabledPlugins` map in `~/.claude/settings.json` needs an explicit `"maude@maude": true`. README's install section calls this out as a step.
3. `hooks/hooks.json` events were at the file root. Claude Code's schema expects them wrapped in a top-level `{"hooks": {...}}` record. Wrapped, both in source and in the marketplace cache copy.

### Known gaps (deliberate v0.1.0 scope)

- Trace JSONL retention/rotation policy — currently unbounded.
- `jq` is a soft dependency; missing → hooks fail silent. Should bundle a fallback or emit a clear error.
- Skill description triggering accuracy unverified at scale.

### Authors

John Broadway built this with Claude (Anthropic). The metaphor — moving into the house, having her own side of the closet, finding what's there instead of bringing baggage — is John's. The character — knowing where everything is, knowing what you need when you need it, keeping you in line by reminding you — is modeled on his wife.
