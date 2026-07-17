#!/usr/bin/env bash
# tests/test-chores-c4-claudemd.sh — staleness needs BOTH age and churn; report is undone.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
TR="$TEST_TMP/.maude/plugin/trace"

test_start "no CLAUDE.md → not due"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c4-claudemd"].due' "$LEDGER")" "false" "no CLAUDE.md not due"

printf '# proj\n' > "$TEST_TMP/CLAUDE.md"; touch_ago $(( 60*86400 )) "$TEST_TMP/CLAUDE.md"

test_start "old but quiet → not due"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c4-claudemd"].due' "$LEDGER")" "false" "old but quiet not due"

for i in $(seq 1 11); do printf '{}\n' > "$TR/today-2026-07-$(printf '%02d' "$i").jsonl"; done

test_start "old + churn → due"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c4-claudemd"].due' "$LEDGER")" "true" "old + churn due"

test_start "run reports undone with counts"
bash "$CH" run c4-claudemd >/dev/null 2>&1
assert_eq "$(jq -r '.["c4-claudemd"].status' "$LEDGER")" "undone" "c4 reports undone"
assert_contains "$(jq -r '.["c4-claudemd"].note' "$LEDGER")" "stale" "note names staleness"

rm -f "$TEST_TMP/CLAUDE.md"
test_start "missing file → fails, not epoch-days fabrication"
bash "$CH" run c4-claudemd >/dev/null 2>&1
assert_eq "$(jq -r '.["c4-claudemd"].status' "$LEDGER")" "failed" "missing file fails"
assert_contains "$(jq -r '.["c4-claudemd"].note' "$LEDGER")" "missing" "note says missing"
assert_not_contains "$(jq -r '.["c4-claudemd"].note' "$LEDGER")" "20650" "no epoch-days in note"

teardown_test_env
exit "$FAILED"
