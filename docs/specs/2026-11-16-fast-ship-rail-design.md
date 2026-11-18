<!-- Version: 0.39.0 -->
<!-- Created: 2026-11-16 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# A ship rail that fails fast and does not rebuild for a sentence

Pinned to: `main` as of 2026-11-16. Status: draft for John's approval.

## What is attempted, and why

`scripts/ship.sh build` turns the source tree into a public ship branch and gates it. On
2026-11-16 one release took six builds of about an hour each. None of the six reds was
found by the slow gates:

| Build | What stopped it | Found by | When in the build |
|---|---|---|---|
| 1 | a CHANGELOG `Revised:` stamp a day behind | `make verify` | after both suites, ~60 min in |
| 2 | two design specs quoting private sessions, boxes and words | review after the build | after a green build |
| 3 | a private service name in a docstring | review after the build | after a green build |
| 4 | another repo's commit hash, a private lane name, a container term | review after the build | after a green build |
| 5 | the macOS-shaped suite timed out under load | `make mac-shape` | ~45 min in |
| 6 | (green) | | |

Build 5's red was caused by a second suite run started beside it (the author's mistake,
not a defect), so it says one more thing: the rail's slowest gates are sensitive to load.

John, 2026-11-16: "yes fix the rail per dev rules and sop"; "go with your pick, write the
spec and we dogfood everything". The aim: a red is found in minutes, not after an hour;
a private name a reviewer would catch is caught by the rail before the first build; and
no gate is skipped or weakened to buy the time.

## Goals

1. **Cheap gates first.** Every gate that runs in seconds runs before the suites, so a
   stale stamp or a lint error costs seconds, not an hour.
2. **A preflight the author can run before building.** `ship.sh preflight` runs the cheap
   gates and the leak audit against the tree the build would stage, without the suites,
   so the author finds a red before committing to an hour.
3. **The audit knows this house's private names.** A private list, kept outside the repo
   and never shipped, holds literals the house has seen leak (a service name, a container
   term, a lane name). The audit refuses an added line that carries one, the same way it
   refuses an IP or a private path today. Generic shapes that are never public-safe in
   added prose (a memory-note filename, a quoted session id) are checked by patterns that
   ship with the rail.
4. **The suites run faster where the measurement says it is safe** (see Measurement).

## Non-goals (these bind the builder)

- No gate is skipped. Not on a "small" diff, not on a docs-only diff, not by a flag. The
  `SHIP_SKIP_GATES` seam stays test-fixture-only.
- No reuse of an earlier build's gate result. Every build gates the tree it ships.
- No change to what any gate checks, except the audit's added patterns and list.
- The public macOS leg is not replaced or weakened; it stays the final word on BSD tools.
- The private list's contents never enter the repo, a log line, a commit, or a PR body. A
  refusal names the file and line of the leak and says "a private name", never the name.
- Nothing in other projects. This is Maude's rail.

## Anti-goals (a failure even if it works)

- A faster rail that goes green on something the old rail would have refused.
- A parallel suite whose reds are noise: a red that appears only under the new runner and
  is "load" is a defect in this design, not in the test.

## Approaches

**A. Reorder and preflight, plus the private-name audit (recommended, with B gated on
measurement).** Move `make lint` and `make verify` ahead of the suites in `cmd_build`;
add `cmd_preflight` that stages the tree exactly as `cmd_build` does, runs `audit_staged`,
lint and verify, and returns the checkout as it found it. Extend `audit_staged` with the
private list and the shipped generic shapes. Mechanism: no gate changes, only order and
coverage. Trade-off: the suites still take their full time once a build starts. Fails
when: a red only a suite can see (a real test failure) still costs the hour; that is the
gate doing its job.

**B. One fleet run per shape, the smoke on the staged tree, files in parallel, capped.**
The build runs the plain fleet once, inside the smoke, against the staged tree; the shaped
pass runs with `MAUDE_SMOKE_SEPARATE=1`; `tests/run.sh` gains a capped pool. Earlier form of
this approach, kept for the record: `tests/run.sh` runs files one by
one. A capped worker pool (`-j N`) cuts wall time, for both the plain and the shaped pass.
Trade-off: load. The shaped pass slows `mkdir` on purpose and several tests bound wall
time; build 5 shows they go red under load. Fails when: N is above what the timing-bound
tests tolerate. Taken only for the files the measurement shows are neither slow-bounded
nor load-sensitive, with those files kept serial, and only if the measured saving is real.

**C. Skip or reuse gates for a small change (rejected, by the author, against John's
standing rule that the bar is never lowered).** A tree-hash cache or a "docs-only" skip
would have saved the five rebuilds, but each fold changed the tree, and a docs-only skip
would have shipped build 2's leak green. Rejected.

**D. Run the plain and shaped suites at the same time (rejected, by the author).** Halves
wall time on paper; build 5 is the measurement that says the shaped suite fails under the
load the plain one adds.

**Recommendation: A, and B as measured: one fleet per shape and the smoke on the staged
tree (no gate lost, a false claim fixed), then the capped pool with the load-sensitive files
serial.** Estimated wall time per build, from the Measurement table: today about 60 min;
with one fleet per shape, sequential, about 43 min; with the pool at the measured N, about
10 to 15 min.

## Measurement (measure first)

Per-file wall time, one file at a time, on an idle 16-core box (load 9.9 falling to 7.9 for
the plain pass, 9.2 to 13.5 for the shaped pass), `main` as of 2026-11-16:

| Piece | Time |
|---|---|
| plain test files, excluding the install smoke | 983 s |
| `test-install-smoke.sh` (it re-runs the whole fleet from a `git archive`) | 812 s |
| `make test-py` | 78 s |
| shaped test files (`MAUDE_SMOKE_SEPARATE=1`, so no nested smoke) | 1,517 s |
| `make lint` | 48 s |
| `make verify` | 1.2 s |

Longest single files, plain / shaped: `test-gate.sh` 310 s / 358 s (since split: the longest
part 64 s), `test-gate-parser.sh` 87 s / 111 s, `test-redteam-watch.sh` 48 s / 86 s.

What the numbers say:

1. **A build runs the whole fleet about four times.** `make test` runs the fleet and then the
   smoke runs it again from an archive; `make mac-shape` runs `make test` again under the
   shape, smoke included. That is the hour.
2. **The build's smoke proves the wrong tree.** `scripts/install-smoke.sh` archives `HEAD`.
   `cmd_build` stages the ship tree in the index and commits it only after the gates, so
   during the build `HEAD` is still public main: the smoke has been proving the tree that is
   already public, not the one about to ship. The PR's own CI smoke proves the right tree,
   which is why nothing escaped; the rail's claim was still false.
3. **The plain fleet is the smoke's fleet.** The smoke runs the same files from the shipped
   archive, which is strictly the stronger proof (it also shows the archive is complete).
   Running them once from the working tree first proves nothing the smoke does not.
4. **Parallel is limited by the longest file.** Before the split, `test-gate.sh` alone set a
   floor of 5 to 6 minutes; after it, the floor is `test-gate-parser.sh` (87 s / 111 s), the
   file that went red under load in build 5.

## Design

### 1. Order in `cmd_build`

After `audit_staged`: `make lint`, then `MAUDE_VERIFY_SOURCE_REF="$SRC" make verify`, then
`make test`, then `make mac-shape`. Same gates, same failure messages, new order.

### 2. `ship.sh preflight`

Builds the staged tree in a **temporary detached worktree** (author's call, from the
builder check: switching the author's checkout would wipe uncommitted work): a worktree at
`$PUB/main`, `read-tree --reset -u "$SRC"`, `.publishignore` stripped, exactly as
`cmd_build` stages. In it, runs `audit_staged` (in a subshell, so its `die` ends only that
gate), lint and verify, **each one even if an earlier one is red**, prints one line per
gate, then removes the worktree on every exit path (a trap). The author's checkout, branch
and index are never touched, so preflight is safe on a dirty tree and from any branch. It
reads `$SRC` (default `main`, `SHIP_SOURCE_REF` as for build). It commits nothing and
pushes nothing. Exit 0 only if all three passed. `cmd_build` is unchanged in what it
gates; preflight is advice the author runs first, never a substitute.

### 3. The private-name list

- Path: `~/.claude/maude/ship-private-names.txt` (user-global, outside every repo, mode
  0600 when the rail creates it). One literal per line; `#` comments; blank lines ignored.
- `audit_staged` reads it when present and refuses an added line containing any literal,
  case-insensitively, at a word boundary. The refusal prints `file:line: a private name
  (from the private list)` and never the literal.
- Absent list: the audit says once "no private-name list; private names are not checked"
  and goes on. It does not fail, so an adopter's rail works without one; on this box the
  list exists.
- Seeded by John's hand or with his word: the rail never writes names into it. The house's
  own seed (the literals today's reviews found) is proposed to John in the handoff, not
  written by the build.

### 4. Shipped generic shapes

Added to `audit_staged`, assembled by concatenation like the existing patterns so the
rail can ship itself, and applied **only to prose** (author's call, from the builder
check: both shapes occur legitimately in code and fixtures, e.g. a gate that names
`now_<lane>.md` and test JSON with a fake session id). Prose is: an added line
in a `*.md` file, or an added line in a `*.sh` or `*.py` file whose first non-blank
character is `#`. Today's leaks in a docstring would not be caught by this rule; the
private list (part 3) is what catches a named service in code. The shapes:
- a memory-note filename: `(project|feedback|now|user|reference)_` or `letter-from-claude-`
  followed by a word and `.md`, or inside a `[[...]]` link;
- a quoted session id: the word `session` followed within two words by 8 or more hex.

Calibration: a test runs the shapes over every prose line of the whole shipped tree
(`$SRC` minus `.publishignore`, not only added lines). Each hit is either a false positive
(the shape is narrowed) or a real leak (scrubbed in this work: one is known today, a
quoted session id in a comment of `tests/test-redteam-watch.sh`, which is fixed here, not
let through by weakening the shape). The test passes on the tree this work ships.

### 5. One fleet run per shape, on the staged tree

- `scripts/install-smoke.sh` takes an optional tree-ish (default `HEAD`, today's behaviour)
  and archives that. `cmd_build` passes the staged index's tree (`git write-tree`), so the
  smoke proves the bytes that ship.
- `cmd_build` runs, after the cheap gates: `make test-py`; the smoke on the staged tree
  (its inner fleet is the plain fleet); then `make mac-shape` with `MAUDE_SMOKE_SEPARATE=1`
  so the shaped pass does not nest a second smoke. Every test file still runs plain (in the
  archive) and shaped; the smoke still runs once.
- `make test` and `make mac-shape` keep their meaning for anyone running them by hand.

### 6. Parallel runner

`tests/run.sh -j N`: a fixed-size pool over the files not on a serial list; the serial list
(`tests/serial.list`, checked in) runs afterwards, one by one. The serial list starts with
the files that bound wall time or went red under load (`test-gate-parser.sh` at least); a
file joins it when the pool turns it red and it is green alone, and the commit says why. N
is chosen by a measured run: the largest N at which ten pooled runs are all green and the
shaped pass stays green. Output order stays
alphabetical (each file's output is buffered and printed in order). The TMPDIR leak check
stays per file. `N` defaults to 1 (today's behaviour); the build passes the measured N.

## Failure modes, security, limits

- The private list is itself sensitive: it is read, never printed, never copied into the
  repo, and a test proves a refusal does not echo it.
- A list entry that is a common word would refuse ordinary prose; the word-boundary rule
  and John's review of the list are the guard.
- Reordering cannot let a red through: every gate still runs and any red still stops the
  build.
- Preflight leaves the checkout as found even when interrupted (a trap restores it), or it
  says exactly how to recover, the way `cmd_build` does today.
- Limit: the audit sees added lines only, as today; a leak already public is not found.

## Test seams

- `tests/test-ship.sh` drives `ship.sh` against fixture repos (it already does, with
  `SHIP_SKIP_GATES`). New cases: gate order (a verify red stops the build before any suite
  runs, seen by a fake `make` that logs its targets); preflight passes, fails, restores the
  branch, commits nothing; a private name in an added line is refused without echoing the
  name; absent list is said once and does not fail; each generic shape is refused, and
  today's public tree passes.
- Parallel runner (if built): `tests/test-suite-runner.sh` gains: same verdicts and same
  output order with `-j 4` as `-j 1`; a serial-listed file never overlaps another file.

## Verification plan

Red first for every behaviour above. Then the dogfood: the next Maude public ship goes
through the new rail, preflight first, and its wall time and every red it finds are
recorded against the six builds in the table above.

## Rollout and rollback

One branch, one commit per part (order, preflight, list, shapes, runner). Each reverts
alone. Nothing is irreversible; the rail ships nothing until John's push line, as today.

## Calls the author made (from the builder check, for John to check while reading)

- Preflight runs in its own temporary worktree, never the author's checkout.
- Preflight runs all three gates and reports each, rather than stopping at the first red.
- The generic shapes read prose only (Markdown, and `#` comment lines in shell and python).
- The one real session id found in a shipped comment is scrubbed in this work.

## Open questions

1. (John, before the list is seeded) Which literals go on the private list. The author
   proposes the ones today's reviews found; John approves the list.
2. (author, gated on the pooled runs) N, and the starting serial list.
