#!/usr/bin/env bash
# tests/test-chores-hooks.sh — Stop wires dispatch; SessionStart wires brief.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
TRACE="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
for i in 1 2 3 4 5 6 7; do
  printf '{"ts":"%s","kind":"prompt","hook":"UserPromptSubmit","tool":null,"target":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
done
printf '{}\n' > "$TEST_TMP/t.jsonl"
# c1's detector requires a .remember/ substrate (else it's never due — see
# test-chores-c1-save.sh for that guard's own coverage); this file is testing
# Stop-wires-dispatch, orthogonal to the substrate question, so give it one.
mkdir -p "$TEST_TMP/.remember"

test_start "stop hook dispatches due chore"
printf '{"transcript_path":"%s"}\n' "$TEST_TMP/t.jsonl" | \
  MAUDE_CHORE_DOER_STUB="true" bash "$HOOKS_DIR/maude-session-stop.sh" >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].status // ""' "$LEDGER")" "dispatched" "stop hook dispatches due chore"

test_start "session start prints chores brief"
bash "$SCRIPTS_DIR/maude-chores.sh" stamp c1-missed-save --arg s done \
  '.["c1-missed-save"] += {status:$s, note:"handoff written"}' >/dev/null 2>&1
OUT="$(bash "$HOOKS_DIR/maude-session-start.sh" 2>/dev/null)"
assert_contains "$OUT" "Chores:" "session start prints chores brief"

test_start "kill switch keeps hooks silent"
OUT="$(MAUDE_CHORES=off bash "$HOOKS_DIR/maude-session-start.sh" 2>/dev/null)"
assert_not_contains "$OUT" "Chores:" "kill switch keeps hooks silent"

teardown_test_env
exit "$FAILED"
