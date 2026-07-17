#!/usr/bin/env bash
# tests/test-chores-c2-reroll.sh — verbatim move, opt-in, refuses collision, forbidden files safe.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
mkdir -p "$TEST_TMP/.remember"
OLD="$TEST_TMP/.remember/today-2026-05-01.md"
printf 'line one\nline two 🔴 OPEN: thing\nline three\n' > "$OLD"
touch_ago $(( 45*86400 )) "$OLD"
printf 'fresh anchor\n' > "$TEST_TMP/.remember/remember.md"
SUM="$(md5sum "$OLD" | cut -d' ' -f1)"

test_start "re-roll is OFF by default (file stays)"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_file_exists "$OLD" "re-roll off by default"

test_start "re-roll on: file moves to archive verbatim"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
ARCH="$TEST_TMP/.remember/archive/today-2026-05-01.md"
assert_file_exists "$ARCH" "moved to archive"

test_start "byte-identical across the move"
assert_eq "$(md5sum "$ARCH" | cut -d' ' -f1)" "$SUM" "byte-identical across the move"

test_start "source removed after verified copy"
assert_file_absent "$OLD" "source removed after verified copy"

test_start "collision refused (archive copy untouched)"
printf 'different\n' > "$OLD"; touch_ago $(( 45*86400 )) "$OLD"; touch "$TEST_TMP/.remember/remember.md"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
assert_eq "$(md5sum "$ARCH" | cut -d' ' -f1)" "$SUM" "collision refused"
assert_file_exists "$OLD" "collision leaves source in place"

test_start "now.md and archive.md never touched"
printf 'live buffer\n' > "$TEST_TMP/.remember/now.md"
printf 'old archive\n' > "$TEST_TMP/.remember/archive.md"
touch_ago $(( 90*86400 )) "$TEST_TMP/.remember/now.md" "$TEST_TMP/.remember/archive.md"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
assert_contains "$(cat "$TEST_TMP/.remember/now.md")" "live buffer" "now.md untouched"
assert_contains "$(cat "$TEST_TMP/.remember/archive.md")" "old archive" "archive.md untouched"

test_start "collision refused when dest is directory-shaped (source survives)"
NEWFILE="$TEST_TMP/.remember/today-2026-05-03.md"
printf 'another 🔴 OPEN: fail test\n' > "$NEWFILE"
touch_ago $(( 45*86400 )) "$NEWFILE"
touch "$TEST_TMP/.remember/remember.md"
# Plant a directory at dest — the collision check `[ -e "$dest" ]` fires before
# cp ever runs, so this exercises the collision-refusal path, NOT cp failure.
mkdir -p "$TEST_TMP/.remember/archive/today-2026-05-03.md"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
assert_file_exists "$NEWFILE" "dir-collision: source survives"

test_start "cp failure cleans partial dest and does not collision-block"
BIG="$TEST_TMP/.remember/today-2026-05-04.md"
head -c 200000 /dev/zero | tr '\0' 'x' > "$BIG"
touch_ago $(( 45*86400 )) "$BIG"
touch "$TEST_TMP/.remember/remember.md"   # fresh anchor so the file is covered+staged
# ulimit -f 16 (16 x 512-byte blocks = 8KB) makes cp of the 200KB file take
# SIGXFSZ mid-write and fail — a real cp failure, not a pre-empted collision.
( ulimit -f 16; MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1 )
assert_file_exists "$BIG" "source survives cp failure"
assert_file_absent "$TEST_TMP/.remember/archive/today-2026-05-04.md" "partial dest cleaned after cp failure"

test_start "rerun after cp failure succeeds (no permanent collision-block)"
MAUDE_REROLL=on bash "$CH" run c2-shelves >/dev/null 2>&1
assert_file_exists "$TEST_TMP/.remember/archive/today-2026-05-04.md" "rerun archives the file"
assert_file_absent "$BIG" "source removed after verified rerun move"

teardown_test_env
exit "$FAILED"
