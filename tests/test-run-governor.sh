#!/usr/bin/env bash
# Tests for hooks/scripts/maude-run-governor.sh — the run-length governor (jacket).
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
GOV="$HOOKS_DIR/maude-run-governor.sh"

test_start "tick from empty state sets actions_since_human=1"
bash "$GOV" tick
assert_eq "$(read_care '.run_state.actions_since_human')" "1" "first tick"

test_start "tick increments again"
bash "$GOV" tick
assert_eq "$(read_care '.run_state.actions_since_human')" "2" "second tick"

test_start "tick initializes last_human_ts (non-null, numeric)"
ts="$(read_care '.run_state.last_human_ts')"
[ "$ts" -gt 0 ] 2>/dev/null
assert_exit "$?" "0" "last_human_ts set"

test_start "reset zeroes actions_since_human"
bash "$GOV" tick; bash "$GOV" tick
bash "$GOV" reset
assert_eq "$(read_care '.run_state.actions_since_human')" "0" "reset to 0"

test_start "reset clears soft_warned"
printf '{"run_state":{"actions_since_human":50,"last_human_ts":1,"soft_warned":true}}\n' > "$(care_path)"
bash "$GOV" reset
assert_eq "$(read_care '.run_state.soft_warned')" "false" "soft_warned cleared"

test_start "tick preserves other care.json keys"
printf '{"gate_cleared":{"x":{"until":9}},"run_state":{"actions_since_human":3}}\n' > "$(care_path)"
bash "$GOV" tick
assert_eq "$(read_care '.gate_cleared.x.until')" "9" "foreign key kept"

test_start "tick is inert (exit 0) without jq"
NOJQ="$(make_nojq_bin)"
PATH="$NOJQ" bash "$GOV" tick >/dev/null 2>&1
assert_exit "$?" "0" "no-jq tick exit 0"

# ── gate mode ─────────────────────────────────────────────────────────────
run_gate() { ERR="$(printf '%s' "${1:-{} }" | bash "$GOV" gate 2>&1 >/dev/null)"; RC=$?; }
seed_rs() { printf '{"run_state":{"actions_since_human":%s,"last_human_ts":%s,"soft_warned":%s}}\n' "$1" "$2" "${3:-false}" > "$(care_path)"; }

test_start "gate passes (exit 0) well under thresholds"
seed_rs 5 "$(date +%s)"; run_gate '{}'
assert_exit "$RC" "0" "under threshold ok"

test_start "gate soft-whispers at the action threshold (exit 0)"
seed_rs 40 "$(date +%s)"; run_gate '{}'
assert_exit "$RC" "0" "soft still passes"
assert_contains "$ERR" "run-governor" "soft whisper present"

test_start "gate sets soft_warned after whispering"
assert_eq "$(read_care '.run_state.soft_warned')" "true" "soft_warned set"

test_start "gate does NOT repeat the soft whisper once warned"
run_gate '{}'
assert_eq "$ERR" "" "no repeat whisper"

test_start "gate HARD-PAUSES (exit 2) at the action ceiling"
seed_rs 80 "$(date +%s)"; run_gate '{}'
assert_exit "$RC" "2" "hard pause"

test_start "gate hard-pause names the file it looked in (the second reader of the yellow token)"
assert_contains "$ERR" "(looked in: " "names the care file it read"
looked="$(printf '%s\n' "$ERR" | sed -n 's/^ *(looked in: \(.*\))$/\1/p' | head -1)"
assert_eq "$looked" "$CLAUDE_PROJECT_DIR/.maude/plugin/care.json" "and it is the file the governor read"

test_start "gate hard-pause message names the override"
assert_contains "$ERR" "/maude:conscience run-governor" "override hint"

test_start "gate HARD-PAUSES on elapsed minutes (100 min since human)"
seed_rs 0 "$(( $(date +%s) - 6000 ))"; run_gate '{}'
assert_exit "$RC" "2" "elapsed hard pause"

test_start "live run-governor token stands the governor DOWN (passes at ceiling)"
NOW=$(date +%s)
printf '{"run_state":{"actions_since_human":80,"last_human_ts":%s,"soft_warned":true},"gate_cleared":{"run-governor":{"until":%s}}}\n' "$NOW" "$((NOW+600))" > "$(care_path)"
run_gate '{}'
assert_exit "$RC" "0" "live token suppresses"

test_start "live token is NOT consumed (rides the window)"
assert_eq "$(read_care '.gate_cleared["run-governor"].until // "absent"')" "$((NOW+600))" "token persists"

test_start "live token also suppresses the SOFT whisper"
printf '{"run_state":{"actions_since_human":40,"last_human_ts":%s,"soft_warned":false},"gate_cleared":{"run-governor":{"until":%s}}}\n' "$NOW" "$((NOW+600))" > "$(care_path)"
run_gate '{}'
assert_eq "$ERR" "" "no whisper while stood down"

test_start "EXPIRED run-governor token does NOT suppress (hard-pauses at ceiling)"
printf '{"run_state":{"actions_since_human":80,"last_human_ts":%s,"soft_warned":false},"gate_cleared":{"run-governor":{"until":1}}}\n' "$NOW" > "$(care_path)"
run_gate '{}'
assert_exit "$RC" "2" "expired token → still pause"

test_start "MAUDE_RUN_GOVERNOR=off makes the gate inert even at ceiling"
seed_rs 80 "$(date +%s)"
ERR="$(printf '{}' | MAUDE_RUN_GOVERNOR=off bash "$GOV" gate 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "off → no pause"

test_start "MAUDE_RUN_GOVERNOR=0 also disables"
seed_rs 80 "$(date +%s)"
printf '{}' | MAUDE_RUN_GOVERNOR=0 bash "$GOV" gate >/dev/null 2>&1
assert_exit "$?" "0" "0 → disabled"

test_start "MAUDE_RUN_GOVERNOR=off makes tick inert too (no state change)"
printf '{}\n' > "$(care_path)"
MAUDE_RUN_GOVERNOR=off bash "$GOV" tick
assert_eq "$(read_care '.run_state.actions_since_human // "none"')" "none" "off → tick no-op"

test_start "governor still ON by default (unset env) hard-pauses at ceiling"
seed_rs 80 "$(date +%s)"; run_gate '{}'
assert_exit "$RC" "2" "default on"

test_start "the conscience escape-hatch command is EXEMPT (never deadlocks)"
seed_rs 80 "$(date +%s)"
run_gate "$(make_bash_tool_input 'bash $CLAUDE_PLUGIN_ROOT/hooks/scripts/maude-clear-gate.sh run-governor')"
assert_exit "$RC" "0" "clear-gate command exempt"

test_start "gate is inert (exit 0) without jq"
NOJQ="$(make_nojq_bin)"
seed_rs 80 "$(date +%s)"
printf '{}' | PATH="$NOJQ" bash "$GOV" gate >/dev/null 2>&1
assert_exit "$?" "0" "no-jq gate fail-open"

print_summary
teardown_test_env
exit $FAILED
