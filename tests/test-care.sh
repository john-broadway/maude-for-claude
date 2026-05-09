#!/usr/bin/env bash
# Tests for hooks/scripts/maude-care.sh — session-duration tracking.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

CARE="$HOOKS_DIR/maude-care.sh"

run_care() {
  ERR="$(printf '{"prompt":"hi"}' | bash "$CARE" 2>&1 >/dev/null)"
  RC=$?
}

test_start "care creates care.json on first run"
run_care
assert_file_exists "$(care_path)" "care.json created"

test_start "care exits 0"
assert_exit "$RC" "0" "exit"

test_start "care records last_date"
date_field="$(read_care '.last_date')"
assert_eq "$date_field" "$(date +%Y-%m-%d)" "today"

test_start "care increments prompts_this_session"
prompts="$(read_care '.prompts_this_session')"
assert_eq "$prompts" "1" "first prompt"

run_care
test_start "care increments prompts on second prompt"
prompts="$(read_care '.prompts_this_session')"
assert_eq "$prompts" "2" "second prompt"

test_start "care does NOT fire long-flag at start"
assert_eq "$ERR" "" "no warning"

# Simulate a long session by backdating session_start
SESS_START=$(($(date +%s) - 5*3600))
TMP="$(mktemp)"
jq --arg ss "$SESS_START" '.session_start = ($ss|tonumber)' "$(care_path)" > "$TMP" && mv "$TMP" "$(care_path)"

test_start "care fires long-flag past 4h threshold"
run_care
assert_contains "$ERR" "Maude:" "long-flag warning"

test_start "long-flag stamped in care.json"
fired="$(read_care '.long_flag_fired')"
assert_eq "$fired" "$(date +%Y-%m-%d)" "stamped today"

test_start "care does not double-fire long-flag same day"
run_care
assert_eq "$ERR" "" "silent on second"

print_summary
teardown_test_env
exit $FAILED
