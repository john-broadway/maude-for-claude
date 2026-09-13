#!/usr/bin/env bash
# Tests for tests/run.sh and for the shape of every test file it runs.
#
# WHY (2026-09-02, the 11th lens on v0.30.1): run.sh keyed PASS/FAIL on the test
# file's exit status alone, and four files ended at print_summary/teardown with no
# `exit "$FAILED"` — so they returned 0 whatever their assertions said. 147
# assertions unenforced, among them the closures this release credits. The
# assertions were right; the file they sat in was a bucket with no bottom.
# Two rails now: every file must exit on its failure count, and the runner reads
# the summary line too, so a file that says "1 failed" can never be reported PASS.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

test_start "every test file exits on its failure count"
missing=""
for t in "$TESTS_DIR"/test-*.sh; do
  # Anchored: the exit must be its own statement at the end of a line
  # (`print_summary; exit $FAILED` counts; `exit 0 # exit "$FAILED"` does not).
  grep -qE '(^|;)[[:space:]]*exit +"?\$\{?FAILED\}?"?[[:space:]]*$' "$t" || missing="$missing $(basename "$t")"
done
assert_eq "${missing:-}" "" "files without exit on \$FAILED:$missing"

# A copy of run.sh in a scratch dir sees only the fixture beside it: same bytes as
# the real runner, no recursion into this suite.
RUNDIR="$TEST_TMP/rundir"; mkdir -p "$RUNDIR"; cp "$TESTS_DIR/run.sh" "$RUNDIR/run.sh"

test_start "the runner reports FAIL when the summary says a failure happened but the exit is 0"
printf '#!/usr/bin/env bash\nprintf "1 passed, 1 failed\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "1" "runner exit"
assert_contains "$OUT" "FAIL  test-fixture.sh" "fixture reported FAIL"

test_start "the runner reports PASS for a clean summary with exit 0 (control)"
printf '#!/usr/bin/env bash\nprintf "2 passed, 0 failed\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"
assert_contains "$OUT" "PASS  test-fixture.sh" "fixture reported PASS"

test_start "the runner still trusts exit 0 with no summary line (ten files report their own way)"
printf '#!/usr/bin/env bash\nprintf "all good\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"

test_start "the runner reports FAIL on a non-zero exit even with a clean summary (control)"
printf '#!/usr/bin/env bash\nprintf "2 passed, 0 failed\\n"\nexit 1\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "1" "runner exit"

# ── Temp hygiene. Earned 2026-09-05: 7,471 leaked /tmp/tmp.* dirs on the dev box, from six
# fixtures one file never removed and the shim bins lib.sh hands to fourteen files, three of
# which sweep them. /tmp
# is a 4G tmpfs there and hit 100% twice, faking a scatter of unrelated failures. Two rails:
# lib.sh gives every file its own TMPDIR root and sweeps it at exit (the fix), and run.sh
# refuses green when a file leaves anything behind (what keeps it fixed).
test_start "a test file's temp dirs are swept when it exits, even ones it never removed"
LEAKY="$TEST_TMP/leaky"; mkdir -p "$LEAKY"
# The fixture sources the REAL lib and makes temp the three ways the suite does: the
# env's own TEST_TMP, a bare mktemp, and a shim bin. It removes none of them.
printf '#!/usr/bin/env bash\n. "%s/lib.sh"\nsetup_test_env\nmktemp -d "$TMPDIR/leak.XXXXXX" >/dev/null\nmake_nojq_bin >/dev/null\nprintf "1 passed, 0 failed\\n"\nexit 0\n' "$TESTS_DIR" > "$RUNDIR/test-fixture.sh"
TMPDIR="$LEAKY" bash "$RUNDIR/test-fixture.sh" >/dev/null 2>&1
assert_eq "$(find "$LEAKY" -mindepth 1 | wc -l | tr -d ' ')" "0" "nothing left under the TMPDIR the file was given"

# The sweep must hold under the two things that can take a trap's path away: a quote in the
# path (a first version expanded the path into the trap string, and one apostrophe in TMPDIR
# broke that string at exit) and a test unsetting the variable the trap reads.
test_start "the sweep holds when TMPDIR carries a quote"
QUOTED="$TEST_TMP/quoted/it's"; mkdir -p "$QUOTED"
printf '#!/usr/bin/env bash\n. "%s/lib.sh"\nmktemp -d "$TMPDIR/leak.XXXXXX" >/dev/null\nprintf "1 passed, 0 failed\\n"\nexit 0\n' "$TESTS_DIR" > "$RUNDIR/test-fixture.sh"
TMPDIR="$QUOTED" bash "$RUNDIR/test-fixture.sh" >/dev/null 2>&1
assert_eq "$(find "$QUOTED" -mindepth 1 | wc -l | tr -d ' ')" "0" "nothing left under a quoted TMPDIR"

test_start "the sweep holds when the file unsets the root's variable"
printf '#!/usr/bin/env bash\n. "%s/lib.sh"\nmktemp -d "$TMPDIR/leak.XXXXXX" >/dev/null\nunset TEST_TMPROOT 2>/dev/null\nprintf "1 passed, 0 failed\\n"\nexit 0\n' "$TESTS_DIR" > "$RUNDIR/test-fixture.sh"
UNSETD="$TEST_TMP/unset"; mkdir -p "$UNSETD"
TMPDIR="$UNSETD" bash "$RUNDIR/test-fixture.sh" >/dev/null 2>&1
assert_eq "$(find "$UNSETD" -mindepth 1 | wc -l | tr -d ' ')" "0" "nothing left after the variable was unset"

test_start "lib.sh refuses to run a file when it cannot make its root, loudly"
printf '#!/usr/bin/env bash\n. "%s/lib.sh"\nprintf "1 passed, 0 failed\\n"\nexit 0\n' "$TESTS_DIR" > "$RUNDIR/test-fixture.sh"
OUT="$(TMPDIR="$TEST_TMP/missing/dir" bash "$RUNDIR/test-fixture.sh" 2>&1)"; RC=$?
assert_exit "$RC" "2" "a file without an isolated root does not run"
assert_contains "$OUT" "mktemp -d failed" "and says why"

test_start "the runner reports FAIL for a file that leaves temp behind, and names the count"
printf '#!/usr/bin/env bash\nmktemp -d "$TMPDIR/leak.XXXXXX" >/dev/null\nprintf "1 passed, 0 failed\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(TMPDIR="$LEAKY" bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "1" "runner exit"
assert_contains "$OUT" "FAIL  test-fixture.sh" "fixture reported FAIL"
assert_contains "$OUT" "1 left in TMPDIR" "the leak is named"
assert_contains "$OUT" "left behind:" "and what was left is listed, so the next leak names its maker"
assert_contains "$OUT" "    TMPDIR/" "listed relative to the suite's TMPDIR"

test_start "the listing survives a TMPDIR carrying a pipe"
PIPED="$TEST_TMP/pi|pe"; mkdir -p "$PIPED"
OUT="$(TMPDIR="$PIPED" bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "1" "runner exit"
assert_contains "$OUT" "    TMPDIR/" "the leaked entry is still listed"

test_start "the runner reports PASS for a file that sources lib.sh and makes temp (control: the sweep, not the guard, carries it)"
printf '#!/usr/bin/env bash\n. "%s/lib.sh"\nsetup_test_env\nmktemp -d "$TMPDIR/leak.XXXXXX" >/dev/null\nprintf "1 passed, 0 failed\\n"\nexit 0\n' "$TESTS_DIR" > "$RUNDIR/test-fixture.sh"
OUT="$(TMPDIR="$LEAKY" bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"
assert_contains "$OUT" "PASS  test-fixture.sh" "fixture reported PASS"

# test-eye-hooks.sh proves its blink workers exited by asking pgrep. Without pgrep that
# wait passed having asked nothing: on 51c62d2, under a PATH built from every executable on
# the box except pgrep, pkill, pidof and pidwait, the file printed "pgrep: command not
# found" and then 12 passed, 0 failed (the messages of 3f14a0b and c63c75f name three of
# those four; the twentieth pass's brief carries that). The controls below do not rebuild
# that PATH: they use make_no_binary_bin, a fixed list minus the tools named. A pgrep
# that is present but answers nothing passes it the same way. So the file now probes the
# instrument on a process it owns and refuses to run when the probe fails. Two ways to
# fail the probe; the suite's own run of test-eye-hooks.sh is the control that it passes.
test_start "the eye test refuses to run when pgrep is absent, before it spawns anything"
NOPG="$(make_no_binary_bin pgrep)"
OUT="$(PATH="$NOPG" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
assert_exit "$RC" "2" "a refusal, not a pass and not a failure count"
assert_contains "$OUT" "this file does not run" "the refusal says so"
assert_not_contains "$OUT" "passed" "no summary line: nothing ran"

test_start "and when pgrep is present but sees nothing"
BLIND="$(make_no_binary_bin pgrep)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BLIND/pgrep"; chmod +x "$BLIND/pgrep"
OUT="$(PATH="$BLIND" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
assert_exit "$RC" "2" "present is not working"
assert_contains "$OUT" "this file does not run" "the refusal says so"
assert_not_contains "$OUT" "passed" "no summary line: nothing ran"

# The probe's pattern ends in a $ anchor because the wait's does. A probe whose only child
# is `sleep 7.<token>` cannot tell an anchored pgrep from one that ignores the anchor, so
# the eighteenth pass dropped the $ and nothing moved. The file now also runs a decoy that
# differs from the probe only past the anchor; a pgrep that drops a trailing $ returns both.
test_start "and when pgrep ignores the anchor"
# The shim strips the anchor and execs the REAL pgrep. On a box without one, the shim
# would exec its own -f, the eye test would refuse for the wrong reason, and this control
# passed having exercised nothing (the nineteenth pass). A control that cannot reach its
# subject fails and says why; it does not pass.
REAL_PGREP="$(command -v pgrep || true)"
assert_ne "$REAL_PGREP" "" "no pgrep to strip the anchor from: this control cannot run its subject here"
if [ -n "$REAL_PGREP" ]; then
  NOANCHOR="$(make_no_binary_bin pgrep)"
  printf '#!/usr/bin/env bash\nexec %q "$1" "${2%%\\$}"\n' "$REAL_PGREP" > "$NOANCHOR/pgrep"; chmod +x "$NOANCHOR/pgrep"
  OUT="$(PATH="$NOANCHOR" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "an anchor the instrument ignores is an anchor the wait does not have"
  assert_contains "$OUT" "this file does not run" "the refusal says so"
  assert_not_contains "$OUT" "passed" "no summary line: nothing ran"
  # Any broken pgrep earns the three lines above (the twentieth pass: a pgrep at a path with
  # a space broke the shim's exec and the control stayed green). Only an anchor-ignoring one
  # matches probe AND decoy, so the refusal must quote two pids.
  assert_eq "$(printf '%s' "$OUT" | tr '\n' ' ' | grep -cE '\$" returned "[0-9]+ [0-9]+" \(the decoy')" "1" "the refusal quotes two pids: probe and decoy both matched"

  # The probe reads its pattern only after the decoy is visible and the probe's own pid is in
  # the capture. A first version read the pattern first and confirmed the decoy after; a
  # decoy that exec'd between the two calls left a stale one-pid capture and the anchor-
  # ignoring pgrep walked through with the decoy delayed 0.5s: 18 of 20 runs for the
  # twentieth pass, 15 of 20 for the author. Delay only the decoy (the token ends in 1, so
  # only the decoy's argument ends in 0) and the refusal must still come.
  # DIR PATTERN DELAY: DIR/sleep delays an argument matching PATTERN by DELAY seconds, then
  # execs the real sleep under its own name. The delay is a child the shim waits on, and a
  # TERM to the shim is forwarded to it (the trap is set before the fork): the twenty-second
  # pass caught the real sleep orphaned for the rest of its delay after the eye test killed
  # the shim, a leak `pgrep -f 'sleep 7\.'` cannot see and a $( ) capture hides by waiting
  # for it. Callers exclude `sleep` from DIR at construction; this writes that one name.
  REAL_SLEEP="$(command -v sleep)"
  make_sleep_shim() {
    printf '#!/usr/bin/env bash\ncase "$1" in %s) trap '"'"'kill "$_c" 2>/dev/null; exit 143'"'"' TERM; %q %s & _c=$!; wait "$_c" ;; esac\nexec -a sleep %q "$@"\n' "$2" "$REAL_SLEEP" "$3" "$REAL_SLEEP" > "$1/sleep"; chmod +x "$1/sleep"
  }
  test_start "and when the decoy is slow to appear"
  SLOWDECOY="$(make_no_binary_bin pgrep sleep)"; make_sleep_shim "$SLOWDECOY" '7.*0' 0.5
  # The pgrep shim answers the probe's pattern from a snapshot taken BEFORE a 0.3s hold, so a
  # decoy that appears during the hold is missing from that answer and present a moment
  # later: the exact window the old ordering read through. Deterministic where a bare delay
  # was a race (the twenty-first pass: 0 of 5 red at n=5 against the old ordering, 4 of 20 at
  # n=20). The decoy's own pattern is answered at once.
  printf '#!/usr/bin/env bash\ncase "$2" in *1\\$) _o="$(%q "$1" "${2%%\\$}")"; _r=$?; %q 0.3; printf "%%s\\n" "$_o"; exit $_r ;; esac\nexec %q "$1" "${2%%\\$}"\n' "$REAL_PGREP" "$REAL_SLEEP" "$REAL_PGREP" > "$SLOWDECOY/pgrep"
  chmod +x "$SLOWDECOY/sleep" "$SLOWDECOY/pgrep"
  OUT="$(PATH="$SLOWDECOY" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "a slow decoy is still a decoy"
  assert_eq "$(printf '%s' "$OUT" | tr '\n' ' ' | grep -cE '\$" returned "[0-9]+ [0-9]+" \(the decoy')" "1" "the refusal quotes two pids"

  # The two-pid line above is what separates the anchor case from any other broken pgrep;
  # weakened to one pid or to .* it matched the decoy check's own pid and stayed green (the
  # twenty-first pass). So a pgrep that is broken some other way must NOT read as two pids.
  test_start "and a pgrep broken some other way is not the anchor case"
  BROKEN="$(make_no_binary_bin pgrep)"
  printf '#!/usr/bin/env bash\nexec /nonexistent/pgrep "$@"\n' > "$BROKEN/pgrep"; chmod +x "$BROKEN/pgrep"
  OUT="$(PATH="$BROKEN" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "still a refusal"
  assert_eq "$(printf '%s' "$OUT" | tr '\n' ' ' | grep -cE '\$" returned "[0-9]+ [0-9]+" \(the decoy')" "0" "no two pids: this refusal is not the anchor case"

  # A probe that has not exec'd by the poll's 2s cap is a refusal too, and the refusal must
  # say what it saw (the decoy and not the probe), not blame the instrument: under a real
  # pgrep the twenty-first pass read "cannot see its own failure" for a probe slowed 2.5s.
  # Slow only the probe, well past the cap, with a delay this run can name.
  test_start "and when the probe is slow to appear, the refusal says so and the delay dies with the shim"
  SLOWPROBE="$(make_no_binary_bin sleep)"; make_sleep_shim "$SLOWPROBE" '7.*1' "4.$$"
  # Not a $( ) capture: the shim's real sleep inherits the pipe, so a capture waits for an
  # orphan to die on its own clock and the check below could never see one (the twenty-second
  # pass caught the orphan only by running the file directly).
  PATH="$SLOWPROBE" bash "$TESTS_DIR/test-eye-hooks.sh" > "$TEST_TMP/slowprobe.out" 2>&1; RC=$?
  OUT="$(cat "$TEST_TMP/slowprobe.out")"
  assert_exit "$RC" "2" "a probe the poll never saw is a refusal"
  assert_contains "$OUT" "the decoy was seen and the probe was not" "and the refusal says which sleep was not seen, not that pgrep is blind"
  assert_eq "$(pgrep -f "sleep 4\.$$\$" | wc -l | tr -d ' ')" "0" "the delay's own sleep died with the shim, not on its own clock"

  # The refusal's sentence is an observation and the causes it leaves open, never a single
  # diagnosis: the twenty-second pass read the one-cause wording clear the instrument for a
  # pgrep that failed the probe's pattern alone (the mirror of the twenty-first's finding),
  # and call a probe that was never asked for "not visible". Each cell asserts the observation
  # clause; the cause list is prose. Every shim dir excludes the one name it writes.
  test_start "and a pgrep that fails the probe's pattern alone is not called latency"
  CELL="$(make_no_binary_bin pgrep)"
  printf '#!/usr/bin/env bash\ncase "$2" in *1\\$) exit 1 ;; esac\nexec %q "$@"\n' "$REAL_PGREP" > "$CELL/pgrep"; chmod +x "$CELL/pgrep"
  OUT="$(PATH="$CELL" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "a refusal"
  assert_contains "$OUT" "the decoy was seen and the probe was not" "the observation"
  assert_not_contains "$OUT" "not the instrument" "and no clause clears the instrument"

  test_start "and a decoy that dies first is not 'neither became visible'"
  CELL="$(make_no_binary_bin sleep)"
  printf '#!/usr/bin/env bash\ncase "$1" in 7.*0) exit 1 ;; esac\nexec -a sleep %q "$@"\n' "$REAL_SLEEP" > "$CELL/sleep"; chmod +x "$CELL/sleep"
  OUT="$(PATH="$CELL" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "a refusal"
  assert_contains "$OUT" "the probe's pattern was never read" "the observation: nothing was read, so nothing is 'not visible'"

  test_start "and a pgrep that prints a line beside the pids is not called a wrong match"
  CELL="$(make_no_binary_bin pgrep)"
  printf '#!/usr/bin/env bash\nprintf "warning: noise\\n" >&2\nexec %q "$@"\n' "$REAL_PGREP" > "$CELL/pgrep"; chmod +x "$CELL/pgrep"
  OUT="$(PATH="$CELL" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "a refusal"
  assert_contains "$OUT" "not a pid list" "the observation"

  # One pid inside the probe capture, the decoy's, beside the decoy check's own: the two-pid
  # line reads 0 here on these bytes and 1 under the one-pid weakening that walked through
  # every other control (the twenty-second pass's matrix, combo 11).
  test_start "and a pgrep that answers the probe's pattern with the decoy's pid is one pid, not two"
  CELL="$(make_no_binary_bin pgrep)"
  printf '#!/usr/bin/env bash\ncase "$2" in *1\\$) exec %q "$1" "${2%%\\$}0\\$" ;; esac\nexec %q "$@"\n' "$REAL_PGREP" "$REAL_PGREP" > "$CELL/pgrep"; chmod +x "$CELL/pgrep"
  OUT="$(PATH="$CELL" bash "$TESTS_DIR/test-eye-hooks.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "a refusal"
  assert_contains "$OUT" "pids other than exactly the probe's" "the observation"
  assert_eq "$(printf '%s' "$OUT" | tr '\n' ' ' | grep -cE '\$" returned "[0-9]+ [0-9]+" \(the decoy')" "0" "one pid inside the probe capture is not two"
fi


# The 31st lens, IMPORTANT-2: run.sh captured every file's output and printed it only on
# FAIL, so a passing file's own count and any NOTE it printed never reached the runner's
# stdout — a suite whose UTF-8 pins silently did not run on a C-only runner reported
# "61/61 test files passed" and nothing else. The count on the PASS line is the diffable
# number; the NOTE line is the file saying out loud what it could not assert.
test_start "a passing file's own count and its NOTE lines reach the runner's output (31st lens, IMPORTANT-2)"
printf '#!/usr/bin/env bash\nprintf "  NOTE  something could not be asserted here\\n"\nprintf "2 passed, 0 failed\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"
assert_contains "$OUT" "PASS  test-fixture.sh  (2 passed, 0 failed)" "the count rides on the PASS line"
assert_contains "$OUT" "NOTE  something could not be asserted here" "the NOTE is not swallowed"


# The 32nd lens, IMPORTANT-7: ten of the sixty-one files print no summary, and their bare
# `PASS  file` was byte-identical to a file whose summary the runner could not read. The
# absence is stated now, not implied.
test_start "a passing file with no summary line says so on its PASS line (32nd lens, IMPORTANT-7)"
printf '#!/usr/bin/env bash\nprintf "all good\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"
assert_contains "$OUT" "PASS  test-fixture.sh  (no summary line; enforced by exit status)" "the absence is named"

# The 33rd lens, IMPORTANT-4: "no summary line" also covered a file whose summary the runner
# could not PARSE, and the new sentence vouched for it. An unreadable count is its own sentence.
test_start "a passing file whose summary the runner cannot read says so, not 'no summary line' (33rd lens, IMPORTANT-4)"
printf '#!/usr/bin/env bash\nprintf "  2 passed, 0 failed\\n"\nexit 0\n' > "$RUNDIR/test-fixture.sh"
OUT="$(bash "$RUNDIR/run.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "runner exit"
assert_contains "$OUT" "PASS  test-fixture.sh  (summary unreadable; enforced by exit status)" "the unreadable count is named"
assert_not_contains "$OUT" "no summary line" "and not called an absence"

print_summary
teardown_test_env
exit "$FAILED"
