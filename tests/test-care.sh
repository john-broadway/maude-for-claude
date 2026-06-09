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

# ── Regression: care must NOT clobber foreign state written by other hooks ──
# care.sh runs every UserPromptSubmit; probe-tier1/gate/drift/pre-tool-use also
# write care.json. care must MERGE its own 5 fields, preserving everyone else's.
# (Before the jq-merge fix, care rewrote the whole file from 5 fields and wiped
#  tier1_*, gate_cleared, and the once-per-day cooldowns every prompt.)
seed_full_care() {
  cat > "$(care_path)" <<EOF
{
  "last_date": "$(date +%Y-%m-%d)",
  "last_active": $(date +%s),
  "session_start": $(date +%s),
  "prompts_this_session": 1,
  "long_flag_fired": "",
  "tier1_last_probe": 1234567890,
  "tier1_up": true,
  "tier1_probed": "127.0.0.1:6379=up ",
  "gate_cleared": {"git-push": {"until": 9999999999}},
  "drift_warned": "$(date +%Y-%m-%d)",
  "claudemd_warned": "$(date +%Y-%m-%d)"
}
EOF
}

test_start "care preserves tier1_up across a prompt"
seed_full_care
run_care
assert_eq "$(read_care '.tier1_up')" "true" "tier1_up survived"

test_start "care preserves tier1_probed across a prompt"
assert_eq "$(read_care '.tier1_probed')" "127.0.0.1:6379=up " "tier1_probed survived"

test_start "care preserves a pending gate_cleared token across a prompt"
assert_eq "$(read_care '.gate_cleared["git-push"].until')" "9999999999" "gate_cleared survived"

test_start "care preserves drift_warned cooldown across a prompt"
assert_eq "$(read_care '.drift_warned')" "$(date +%Y-%m-%d)" "drift_warned survived"

test_start "care preserves claudemd_warned cooldown across a prompt"
assert_eq "$(read_care '.claudemd_warned')" "$(date +%Y-%m-%d)" "claudemd_warned survived"

test_start "care still increments its own field while merging"
assert_eq "$(read_care '.prompts_this_session')" "2" "prompts incremented over seed"

# ── Self-heal: a corrupt (non-empty, invalid-JSON) care.json must recover ──
# The old whole-file rewrite self-healed corruption every prompt. The jq-merge
# must NOT regress that: a truncated/garbled care.json should be reseeded so the
# merge succeeds and state isn't frozen forever. (Foreign keys are lost in this
# rare recovery — acceptable: recover once vs. freeze every turn.)
test_start "care reseeds and recovers from a corrupt non-empty care.json"
printf 'this is not valid json {{{' > "$(care_path)"
run_care
# After recovery the file must be valid JSON again (read_care returns a real value).
assert_eq "$(read_care '.prompts_this_session')" "1" "own field written after reseed"

test_start "recovered care.json is valid JSON"
jq -e . "$(care_path)" >/dev/null 2>&1
assert_exit "$?" "0" "valid JSON after recovery"

print_summary
teardown_test_env
exit $FAILED
