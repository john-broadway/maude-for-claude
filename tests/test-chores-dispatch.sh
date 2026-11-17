#!/usr/bin/env bash
# tests/test-chores-dispatch.sh — dispatch flock/stamp (driven by c2-shelves; c1 is retired 2026-11-12).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
TRACE="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
# c1's detector requires a .remember/ substrate (else it's never due — see
# test-chores-c1-save.sh for that guard's own coverage); this file tests
# threshold/dispatch/flock behavior, orthogonal to the substrate question.
mkdir -p "$TEST_TMP/.remember"
# Prevent c3-extension from being due (c3 seeding requires an empty cache, but we
# test c1 dispatch behavior only — seed c3 first so it's not due during dispatch tests).
CACHE="$TEST_TMP/cache"
mkdir -p "$CACHE"
export MAUDE_PLUGIN_CACHE="$CACHE"
bash "$CH" run c3-extension >/dev/null 2>&1

# c2-shelves is the vehicle: due whenever a daily older than the shelf window sits in
# the memory dir. (c1 was the vehicle until it was retired, 2026-11-12.)
export MAUDE_MEM_DIR_OVERRIDE="$TEST_TMP/mem"; mkdir -p "$MAUDE_MEM_DIR_OVERRIDE"
printf 'old day\n' > "$MAUDE_MEM_DIR_OVERRIDE/today-2020-01-01.md"
touch -t 202001010000 "$MAUDE_MEM_DIR_OVERRIDE/today-2020-01-01.md"

# Plant 7 uncaptured prompt events (no capture anchor exists → all uncaptured).
for _ in 1 2 3 4 5 6 7; do
  printf '{"ts":"%s","kind":"prompt","hook":"UserPromptSubmit","tool":null,"target":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
done

test_start "c1 is retired: never due, even past its old threshold"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].due' "$LEDGER")" "false" "c1 never due"

test_start "c2-shelves is due with an aged daily on the shelf"
assert_eq "$(jq -r '.["c2-shelves"].due' "$LEDGER")" "true" "c2 due"

# dispatch: stub the run verb via MAUDE_CHORE_DOER_STUB (writes marker, sleeps)
STUB_LOG="$TEST_TMP/doer-calls.log"
test_start "dispatch stamps dispatched and backgrounds"
bash "$CH" detect >/dev/null 2>&1
MAUDE_CHORE_DOER_STUB="printf '%s\n' ran >> $STUB_LOG; sleep 2" \
  bash "$CH" dispatch "/tmp/fake-transcript.jsonl" >/dev/null 2>&1
assert_eq "$(jq -r '.["c2-shelves"].status' "$LEDGER")" "dispatched" "dispatch stamps dispatched"

test_start "flock prevents double-fire"
LAST_RUN_BEFORE="$(jq -r '.["c2-shelves"].last_run' "$LEDGER")"
MAUDE_CHORE_DOER_STUB="printf '%s\n' ran >> $STUB_LOG; sleep 2" \
  bash "$CH" dispatch "/tmp/fake-transcript.jsonl" >/dev/null 2>&1
sleep 3
assert_eq "$(wc -l < "$STUB_LOG" | tr -d ' ')" "1" "flock prevents double-fire"

test_start "blocked dispatch doesn't update last_run (regression: stamp gate)"
LAST_RUN_AFTER="$(jq -r '.["c2-shelves"].last_run' "$LEDGER")"
assert_eq "$LAST_RUN_AFTER" "$LAST_RUN_BEFORE" "last_run unchanged when dispatch blocked"

teardown_test_env
exit "$FAILED"
