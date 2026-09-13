#!/usr/bin/env bash
# Tests for scripts/install-smoke.sh — the prove-it-real gate: the SHIPPED
# shape (git archive of HEAD) must validate, pass its own fleet, and greet
# from a pristine HOME. A clean working tree is not a clean commit.

set -u
# Recursion guard: inside an install-smoke run, this test self-skips —
# the smoke runs the archive's fleet, which contains this very file.
[ "${MAUDE_INSTALL_SMOKE:-}" = "1" ] && { echo "  ok    (self-skip inside install-smoke)"; exit 0; }
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

SMOKE="$(cd "$DIR/../scripts" && pwd)/install-smoke.sh"
ROOT="$(cd "$DIR/.." && pwd)"

test_start "smoke gate passes on the current HEAD"
OUT="$(bash "$SMOKE" "$ROOT" 2>&1)"; RC=$?
assert_exit "$RC" "0" "smoke green on HEAD"
assert_contains "$OUT" "SMOKE GREEN" "verdict line printed"

test_start "smoke proves the ARCHIVE, not the working tree"
assert_contains "$OUT" "archive" "runs from a git-archive of HEAD"

test_start "a commit missing its parts fails the gate loud"
BROKEN="$TEST_TMP/broken-repo"
git init -q "$BROKEN"
mkdir -p "$BROKEN/.claude-plugin"
printf '{"name":"broken","version":"0.0.1"}\n' > "$BROKEN/.claude-plugin/plugin.json"
git -C "$BROKEN" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$BROKEN" -c user.name=t -c user.email=t@t commit -qm init
bash "$SMOKE" "$BROKEN" >/dev/null 2>&1
RC2=$?
[ "$RC2" -ne 0 ] && BROKE=yes || BROKE=no
assert_eq "$BROKE" "yes" "incomplete commit fails the smoke"

# A red inner fleet must NAME what failed: the smoke used to discard the fleet's output, so
# a runner where every suite passed on its own and only the archive's run went red left
# nothing to read (GitHub macOS, 2026-09-13).
test_start "a red inner fleet names its failing file in the smoke's output"
LOUD="$TEST_TMP/loud-repo"
git init -q "$LOUD"
mkdir -p "$LOUD/.claude-plugin" "$LOUD/tests"
printf '{"name":"loud","version":"0.0.1"}\n' > "$LOUD/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "FAIL  test-zz-fake.sh  (exit 1, 1 failed by its own count, 0 left in TMPDIR)\\n    FAIL  the fake pin\\n0/1 test files passed\\n"\nexit 1\n' > "$LOUD/tests/run.sh"
git -C "$LOUD" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$LOUD" -c user.name=t -c user.email=t@t commit -qm init
OUT3="$(bash "$SMOKE" "$LOUD" 2>&1)"; RC3=$?
assert_ne "$RC3" "0" "the loud repo fails the smoke"
assert_contains "$OUT3" "fleet    : FAIL" "the fleet line is red"
assert_contains "$OUT3" "FAIL  test-zz-fake.sh" "and the failing file is named"
assert_contains "$OUT3" "0/1 test files passed" "with the fleet's own summary"

print_summary
teardown_test_env
exit $FAILED
