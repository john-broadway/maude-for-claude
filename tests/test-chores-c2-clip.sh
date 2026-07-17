#!/usr/bin/env bash
# tests/test-chores-c2-clip.sh — coupon-cut finds planted markers; staging respects coverage.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
COUPONS="$TEST_TMP/.maude/plugin/coupons.md"
STAGED="$TEST_TMP/.maude/plugin/chore-c2-staged.txt"
mkdir -p "$TEST_TMP/.remember"

OLD="$TEST_TMP/.remember/today-2026-06-01.md"
printf '# old day\n🔴 verify the offsite backup copy\ndone stuff\n' > "$OLD"
touch_ago $(( 20*86400 )) "$OLD"
FRESH="$TEST_TMP/.remember/today-$(date -u +%Y-%m-%d).md"
printf '# fresh day\nTODO not aged yet\n' > "$FRESH"
# Coverage anchor newer than OLD: a fresh remember.md
printf 'handoff\n' > "$TEST_TMP/.remember/remember.md"

test_start "c2 due when a daily aged past the shelf"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c2-shelves"].due' "$LEDGER")" "true" "c2 due when a daily aged past the shelf"

test_start "clip finds the planted marker in the aged daily"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_contains "$(cat "$COUPONS" 2>/dev/null)" "verify the offsite backup" "clip finds planted marker"

test_start "fresh daily is not clipped"
assert_not_contains "$(cat "$COUPONS" 2>/dev/null)" "not aged yet" "fresh daily is not clipped"

test_start "clip is idempotent (no dup on second run)"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_eq "$(grep -cF 'verify the offsite backup' "$COUPONS")" "1" "clip is idempotent"

test_start "aged+covered daily is staged for re-roll"
assert_contains "$(cat "$STAGED" 2>/dev/null)" "today-2026-06-01.md" "aged+covered daily staged"

test_start "uncovered daily is NOT staged"
rm -f "$TEST_TMP/.remember/remember.md"
UNCOV="$TEST_TMP/.remember/today-2026-06-02.md"
printf 'lonely uncovered day\n' > "$UNCOV"; touch_ago $(( 20*86400 )) "$UNCOV"
# make everything else older than any anchor source
while IFS= read -r _j; do touch_ago $(( 30*86400 )) "$_j"; done \
  < <(find "$TEST_TMP/.maude" -name '*.json' 2>/dev/null)
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_not_contains "$(cat "$STAGED" 2>/dev/null)" "today-2026-06-02.md" "uncovered daily is NOT staged"

test_start "c2 stamped done"
assert_eq "$(jq -r '.["c2-shelves"].status' "$LEDGER")" "done" "c2 stamped done"

# ── Fix 1: dedup is exact-line, not substring-containment ─────────────────
# Sequential runs (not simultaneous) so file-visitation order can't mask the
# bug: clip the LONG marker first, in its own run, so it is already sitting in
# coupons.md/coupons.keys BEFORE the DISTINCT short marker is ever considered.
test_start "dedup exact-line: a longer marker clipped first doesn't swallow a distinct shorter one"
LONG="$TEST_TMP/.remember/today-2026-06-03.md"
printf '# aged day\nTODO fix login page thoroughly and add tests\n' > "$LONG"
touch_ago $(( 20*86400 )) "$LONG"
bash "$CH" run c2-shelves >/dev/null 2>&1
SHORT="$TEST_TMP/.remember/today-2026-06-04.md"
printf '# aged day\nTODO fix login\n' > "$SHORT"
touch_ago $(( 20*86400 )) "$SHORT"
bash "$CH" run c2-shelves >/dev/null 2>&1
COUPONS_NOW="$(cat "$COUPONS" 2>/dev/null)"
assert_contains "$COUPONS_NOW" "today-2026-06-03.md: TODO fix login page thoroughly and add tests" \
  "long marker clipped"
assert_contains "$COUPONS_NOW" "today-2026-06-04.md: TODO fix login" \
  "distinct short marker NOT dropped as a substring of the long one"

# ── Fix 2: no per-file count cap; a pathological line is length-bounded ───
test_start "no cap: more than 20 markers in one aged file all clip"
MANY="$TEST_TMP/.remember/today-2026-06-06.md"
{
  printf '# aged day\n'
  for i in $(seq 1 25); do printf 'TODO marker number %02d\n' "$i"; done
} > "$MANY"
touch_ago $(( 20*86400 )) "$MANY"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_contains "$(cat "$COUPONS" 2>/dev/null)" "TODO marker number 25" \
  "marker beyond the old 20-cap still clips"

test_start "pathological long line is bounded to 400 chars (tail truncated)"
LONGLINE="$TEST_TMP/.remember/today-2026-06-07.md"
{
  printf '# aged day\n'
  printf 'TODO %s TAIL-MARKER-BEYOND-400\n' "$(printf 'x%.0s' $(seq 1 450))"
} > "$LONGLINE"
touch_ago $(( 20*86400 )) "$LONGLINE"
bash "$CH" run c2-shelves >/dev/null 2>&1
assert_not_contains "$(cat "$COUPONS" 2>/dev/null)" "TAIL-MARKER-BEYOND-400" \
  "line length bounded — tail beyond char 400 truncated"

# ── Fix 3: auto-memory pile clips but is NEVER staged (byte-identical) ─────
test_start "mem-pile marker clips but is never staged; file untouched"
MEMDIR="$TEST_TMP/mem"
mkdir -p "$MEMDIR"
export MAUDE_MEM_DIR_OVERRIDE="$MEMDIR"
MEMFILE="$MEMDIR/today-2026-06-05.md"
printf '# mem day\n🔴 mem-pile marker survives\n' > "$MEMFILE"
touch_ago $(( 20*86400 )) "$MEMFILE"
# Fresh anchor present (remember.md exists) — covers .remember/ dailies for
# staging; irrelevant to the mem-pile file, which the case-guard never matches.
printf 'handoff\n' > "$TEST_TMP/.remember/remember.md"
MD5_BEFORE="$(md5sum "$MEMFILE" | awk '{print $1}')"
bash "$CH" run c2-shelves >/dev/null 2>&1
MD5_AFTER="$(md5sum "$MEMFILE" | awk '{print $1}')"
assert_contains "$(cat "$COUPONS" 2>/dev/null)" "mem-pile marker survives" \
  "mem-pile marker IS clipped to coupons.md"
assert_not_contains "$(cat "$STAGED" 2>/dev/null)" "today-2026-06-05.md" \
  "mem-pile file NOT staged for re-roll"
assert_file_exists "$MEMFILE" "mem-pile file still exists"
assert_eq "$MD5_AFTER" "$MD5_BEFORE" "mem-pile file byte-identical (untouched)"

teardown_test_env
exit "$FAILED"
