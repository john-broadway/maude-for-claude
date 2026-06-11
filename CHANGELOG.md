<!-- Version: 0.3.1 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-06-10 CDT -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Changelog

The Maude Claude Code plugin.

---

## v0.3.1 — held to her own bar: a post-release review pass (2026-06-10)

v0.3.0 shipped without the pre-release multi-agent review its sibling projects get — so it got
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
