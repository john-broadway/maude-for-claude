#!/usr/bin/env bash
# tests/test-chores-ledger.sh — ledger creation, stamp, brief silence/voice, kill switch.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"

test_start "detect creates ledger"
bash "$CH" detect >/dev/null 2>&1
assert_file_exists "$LEDGER" "detect creates ledger"

test_start "ledger is valid json object"
assert_eq "$(jq -r 'type' "$LEDGER" 2>/dev/null)" "object" "ledger is valid json object"

test_start "brief silent on empty ledger"
assert_eq "$(bash "$CH" brief 2>/dev/null)" "" "brief silent on empty ledger"

test_start "stamp merges status"
bash "$CH" stamp c9-test --arg s "done" --arg n "hi" '.["c9-test"] += {status:$s, note:$n}' >/dev/null 2>&1
assert_eq "$(jq -r '.["c9-test"].status' "$LEDGER")" "done" "stamp merges status"

test_start "brief voices a done chore"
assert_contains "$(bash "$CH" brief 2>/dev/null)" "c9-test" "brief voices a done chore"

test_start "kill switch silences everything"
assert_eq "$(MAUDE_CHORES=off bash "$CH" brief 2>/dev/null)" "" "kill switch silences everything"

# Critical 2 regression — the chore_stamp lost-update race. Concurrent
# doers' read(jq)->mv on chores.json used to lose updates (reviewer: 8/15
# trials) because nothing serialized the critical section. chore_stamp now
# holds a ledger-level flock (blocking, not -n — a doer must never lose its
# write). Fire 10 parallel stamps on 10 distinct keys through the
# MAUDE_CHORES_LIB seam and confirm every single one lands.
test_start "10 parallel chore_stamp calls on distinct keys all land"
(
  # shellcheck source=/dev/null
  MAUDE_CHORES_LIB=1 . "$CH"
  for i in $(seq 1 10); do
    chore_stamp "race-$i" --arg s "done" ".[\"race-$i\"] += {status:\$s}" &
  done
  wait
)
N="$(jq '[to_entries[] | select(.key | startswith("race-")) | select(.value.status=="done")] | length' "$LEDGER" 2>/dev/null)"
assert_eq "$N" "10" "all 10 concurrent chore_stamp calls landed"

teardown_test_env
exit "$FAILED"
