<!-- Version: 0.27.2 -->
<!-- Created: 2026-06-30 CDT -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Gate bypass hardening — close 6 of 9 documented limitations — design

> **Design doc (2026-06-30).** Captures the design *as planned*. Closes six of the nine
> bypasses enumerated in `hooks/scripts/maude-gate.sh`'s "Known limitations" block. The exact
> regex shapes here are the intent; the shipped patterns are whatever the tests prove. Rots in
> place by design — the authoritative list of what the gate does and does NOT catch lives in
> the gate source, not here.

## The problem

`maude-gate.sh` hard-blocks irreversible Bash (force-push, `rm -rf` of root/glob/sole-copy,
history rewrites). Its own source documents **nine** ways the regex belt is bypassed. Six are
tractable to close without giving the gate shell semantics it can't safely have. Three are not,
and stay documented limitations.

**Closing (6):**

| # | Bypass | Example |
|---|---|---|
| 1 | Interior double-slash | `rm -rf /srv//app` |
| 2 | Path traversal | `rm -rf /srv/app/../app` |
| 3 | Shell wrapping (partial) | `bash -c "rm -rf /srv/app"` |
| 6 | Absolute-path invocation | `/bin/rm -rf …` |
| 7 | `command` builtin prefix | `command rm -rf …` |
| 8 | Env-assignment prefix | `FOO=1 rm -rf …` |

**Leaving (3) — need real shell semantics; past attempts reopened false-blocks:**

| # | Bypass | Why left |
|---|---|---|
| 4 | Variable indirection (`P=/x; rm -rf $P`) | Gate sees `$P`, not its value. |
| 5 | `cd` + relative delete (`cd /srv && rm -rf .`) | Gate can't track cwd. |
| 9 | Heredoc mis-detection | Narrowing reopens the `<<'EOF'` doc-body false-block. |

## Principle (the fail-direction contract)

Every change makes the matcher catch **more** — it closes under-blocks. It must never make the
gate catch something it shouldn't: **the only risk this work introduces is a new false-block.**
So each fix carries an explicit false-block bound and an executable test that proves a
near-miss command still passes. Matched commands reuse the **existing** gate keys
(`rm-rf-root`, `force-push`, …) so `/maude:conscience` clearing and the YELLOW/RED severity
tiers are unchanged.

This is a **patch** release (bug-fix class): `0.13.1 → 0.13.2`. Local + gitea only. No public
push without John's explicit go (publishing is a separate deliberate act).

## Architecture decision

To inspect a wrapped command (`bash -c '…'`), the gate must re-run its own patterns against the
inner string. **Chosen approach: refactor the gate's inline pattern-matching loop into a
reusable function** `maude_gate_eval "$cmd"` (returns the matched `key|msg` or nothing), then
call it recursively on extracted payloads. This handles nesting (`bash -c "sh -c '…'"`)
naturally and keeps the inspectable-vs-uninspectable whisper distinction clean. (Rejected
alternative: a standalone preprocessor that expands payloads into the command string before a
single-pass match — simpler, but it muddies the whisper distinction and the recursion.)

Normalization helpers live in `_maude-common.sh` beside the existing `maude_strip_quotes` /
`maude_unquote` / `maude_match_gate_pattern`. Anchor fragments (`CMD_START`, `RMR`, `GIT`,
`FLAG_AFTER`) and the pattern tables live in `maude-gate.sh`.

## Delivered in two verified increments

Splitting isolates regression risk; it does not shrink scope. Both increments ship, each behind
a green suite.

### Increment 1 — normalization cluster (#1, #2, #6, #7, #8)

Low-risk, coherent: "make the matcher robust to trivial obfuscation." Lands first.

- **#1 interior `//`** — collapse `/{2,}` → `/` in the path-matching (`maude_unquote`) view
  before path patterns run. Safe: collapsing only ever makes a path *more* canonical, so it can
  match the canonical sole-copy/root patterns; it cannot manufacture a path that wasn't there.

- **#2 path traversal `..`** — lexically canonicalize `/<seg>/../` → `/` in a **capped** loop
  (iterate until stable or N iterations; purely string-level, never touches the filesystem).
  Applied to the path-matching view. Correctness notes that are *not* false-blocks:
  - `rm -rf /tmp/..` resolves to `/` and **should** block — `/tmp/..` *is* `/`.
  - `/tmp/x/../safe` → `/tmp/safe` (the `..` pops `x`, not `tmp`) — must still **pass**.
  - **Residual (documented):** leading-`..` shapes at root the lexical canonicalizer can't
    resolve (e.g. `/../b`) stay uncaught. #2 narrows; it does not vanish.

- **#6 / #7 / #8 — one `PREFIX` anchor fragment.** A transparent-prefix chain matched between
  `CMD_START` and the command keyword:
  - env-assignment(s): `([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*` (#8)
  - `command ` builtin: `(command[[:space:]]+)*` (#7)
  - absolute-path prefix on the command name: change `RMR`/`GIT` to allow optional
    `(/[^[:space:]]*/)?` before the bareword (`/bin/rm`, `/usr/bin/git`) (#6)

  Because `PREFIX` is an anchor fragment inserted into the shared pattern table, **every**
  pattern gains it — `FOO=1 git push --force` and `command git push` get caught too, not just
  `rm`. The `maude_rm_in_command_position` command-position regex gets the same prefix
  treatment.
  - **Boundary safety (must be tested):** `rmdir` / `/usr/bin/rmdir` must still pass (RMR
    requires whitespace after `rm` before a recursive flag; `rmdir` has none). `command` as a
    substring of `mycommand` must not trigger the prefix.

### Increment 2 — shell wrapping (#3, partial)

Highest regression risk — it rides the `maude_gate_eval` refactor, and this gate has a bug
history (v0.1.5 self-block, v0.13.1 newline bypass). Its own increment, its own green gate.

- **Extract** the payload from `bash -c` / `sh -c` / `dash -c` / `zsh -c` and `eval '…'`.
  Handles `-lc`/combined flags, flags before `-c` (`bash --norc -c …`), and args after the
  payload (`bash -c '…' arg0`). **Biases toward under-extraction when ambiguous** —
  under-extract → under-block (acceptable); mis-extract → false-block (not acceptable).
- **Re-run** `maude_gate_eval` on the extracted payload (recursion capped ~3 for nesting).
  Block iff the inner command is itself gated, **with the inner command's key** (so a wrapped
  `rm -rf /` clears as `rm-rf-root`, a wrapped force-push as `force-push`).
- **Inspectable vs not:**
  - single-quoted payload → literal → **inspect**.
  - double-quoted payload with an **interpolated `$`** → uninspectable → **pass + whisper**.
  - bareword / `$VAR` payload → uninspectable → **pass + whisper**.
- **Whisper** = `printf 'Maude: …' >&2; exit 0` — non-blocking notice
  ("`bash -c` with a payload I can't inspect — you're flying without the gate here"). Consistent
  with the already-accepted #4 variable-indirection stance: noticed, not gated. Zero legit work
  blocked.
- **Residual (documented):** heredoc-fed-shell (`bash <<EOF … rm -rf / … EOF`) and variable
  payloads stay uncaught. **#3 narrows to its residual — it is not deleted.**

## Honest-seam requirement (load-bearing, not optional)

The numbered "Known limitations" block in `maude-gate.sh` is rewritten to tell the **exact**
truth, not deleted:

- #1, #6, #7, #8 → removed (closed).
- #2 → narrowed to the leading-`..`-at-root residual.
- #3 → narrowed: `-c` literal payloads inspected; heredoc-fed-shell and variable/interpolated
  payloads remain uncaught (and now emit a whisper).
- #4, #5, #9 → unchanged.
- New seams added: whisper-on-interpolation; under-extraction bias on wrapper parsing.

The doc claiming more closure than the code delivers is itself the failure mode this project
must avoid. The gate source — not this spec — is the authoritative statement of what is and is
not caught.

## Definition of done

1. **`bash -n`** on `maude-gate.sh` and `_maude-common.sh` after *every* edit, before anything
   else. This gate runs as the live PreToolUse Bash hook **this session**; a syntax error blocks
   all Bash (it has happened — the cherry-pick git-marker incident). No-op stub recovery kept in
   pocket (Write is not gated, so a stub can restore the hook).
2. **Baseline the suite green before any change** (was 25/25), so a later red is unambiguously
   ours. TDD: every fix is a RED→GREEN regression test first.
3. **Executable test table** for the false-block traps (below), not eyeballing.
4. **One script proven to do both** exit-2-block and exit-0-whisper (the whisper precedent,
   bash-watch, is a *separate* hook — confirm the channel surfaces from inside
   `maude-gate.sh`'s control flow).
5. Limitations block tells the exact truth. **shellcheck clean.** Full suite green. CHANGELOG
   entry (patch, with the honest seam noted). Version bumped `0.13.1 → 0.13.2` across the
   canonical surfaces (`plugin.json`, `marketplace.json`, CHANGELOG header, CLAUDE.md).

## Test table (must be executable, must pass)

**Closes (newly blocked):**
- `rm -rf /srv//app` → block (sole-copy/path key) — #1
- `rm -rf /tmp/..` → block (`rm-rf-root`) — #2
- `/bin/rm -rf /` → block (`rm-rf-root`) — #6
- `command rm -rf /` → block (`rm-rf-root`) — #7
- `FOO=1 rm -rf /` → block (`rm-rf-root`) — #8
- `FOO=1 git push --force` → block (`force-push`) — #8 generalization
- `bash -c 'rm -rf /'` → block (`rm-rf-root`, inner key) — #3
- `sh -c "git push --force"` (no `$`) → block (`force-push`) — #3

**Must still pass (false-block traps):**
- `rmdir /tmp/x` and `/usr/bin/rmdir /tmp/x` → pass
- `mycommand --flag` (contains `command`) → pass
- `rm -rf /tmp/x/../safe` → pass (canonicalizes to `/tmp/safe`)
- `bash -c 'ls'` → pass, silent
- commit message / heredoc body literally containing `rm -rf /` or `git push` → pass (no
  self-block — the existing quote/heredoc handling must survive the refactor)

**Whisper, NOT block:**
- `bash -c "rm -rf $VAR"` → pass + whisper
- `eval "$DYNAMIC"` → pass + whisper

**Canonicalizer as a pure function (unit):**
- `/tmp/../` → resolves to `/` (block path)
- `/tmp/x/../safe` → `/tmp/safe` (no block)
- `/srv/app/../..` → resolves to `/` (block path)
- `/srv//app` → `/srv/app`
