#!/usr/bin/env bash
# tests/test-chores-c2-reroll.sh: the c2 re-roll is RETIRED (2026-11-12).
#
# With MAUDE_REROLL=on, c2 used to move cold remember dailies into <store>/archive/ and
# delete the originals. That store is the remember plugin's own, and its consolidation
# retires its own dailies; Maude moves nothing there (John's ruling 4, "keep it at its
# peak handling"; the review of 2026-11-12 found the re-roll still did).
# Design: docs/specs/2026-11-11-the-circle-design.md (What retires).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
mkdir -p "$TEST_TMP/.remember"
OLD="$TEST_TMP/.remember/today-2026-05-01.md"
printf 'line one\nline two OPEN: thing\nline three\n' > "$OLD"
touch_ago $(( 45*86400 )) "$OLD"
SUM="$(file_digest "$OLD")"

test_start "re-roll off: the cold daily stays"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_eq "$(file_digest "$OLD")" "$SUM" "untouched"

test_start "re-roll ON: the cold daily still stays, byte for byte, and no archive dir is made"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
assert_eq "$(file_digest "$OLD")" "$SUM" "untouched with MAUDE_REROLL=on"
assert_file_absent "$TEST_TMP/.remember/archive" "no archive dir"

test_start "c2 still clips the daily's open marker into Maude's own closet"
assert_contains "$(cat "$TEST_TMP/.maude/plugin/coupons.md" 2>/dev/null)" "OPEN: thing" "clipped"

teardown_test_env
exit "$FAILED"
