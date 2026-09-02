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

print_summary
teardown_test_env
exit "$FAILED"
