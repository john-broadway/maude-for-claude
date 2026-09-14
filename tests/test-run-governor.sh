#!/usr/bin/env bash
# Tests for hooks/scripts/maude-run-governor.sh — the run-length governor (jacket).
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
GOV="$HOOKS_DIR/maude-run-governor.sh"

test_start "tick from empty state sets actions_since_human=1"
printf '{}' | bash "$GOV" tick
assert_eq "$(read_care '.run_state.actions_since_human')" "1" "first tick"

test_start "tick increments again"
printf '{}' | bash "$GOV" tick
assert_eq "$(read_care '.run_state.actions_since_human')" "2" "second tick"

test_start "tick initializes last_human_ts (non-null, numeric)"
ts="$(read_care '.run_state.last_human_ts')"
[ "$ts" -gt 0 ] 2>/dev/null
assert_exit "$?" "0" "last_human_ts set"

test_start "reset zeroes actions_since_human"
printf '{}' | bash "$GOV" tick; printf '{}' | bash "$GOV" tick
bash "$GOV" reset
assert_eq "$(read_care '.run_state.actions_since_human')" "0" "reset to 0"

test_start "reset clears soft_warned"
printf '{"run_state":{"actions_since_human":50,"last_human_ts":1,"soft_warned":true}}\n' > "$(care_path)"
bash "$GOV" reset
assert_eq "$(read_care '.run_state.soft_warned')" "false" "soft_warned cleared"

test_start "tick preserves other care.json keys"
printf '{"gate_cleared":{"x":{"until":9}},"run_state":{"actions_since_human":3}}\n' > "$(care_path)"
printf '{}' | bash "$GOV" tick
assert_eq "$(read_care '.gate_cleared.x.until')" "9" "foreign key kept"

test_start "tick is inert (exit 0) without jq"
NOJQ="$(make_nojq_bin)"
printf '{}' | PATH="$NOJQ" bash "$GOV" tick >/dev/null 2>&1
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
printf '{}' | MAUDE_RUN_GOVERNOR=off bash "$GOV" tick
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

# ── One quantity, one name: both whispers describe the same two numbers in the same
# words, and name no one person (the UX lens, 2026-09-06, N2). ──
test_start "the soft and hard whispers name the count and the clock the same way"
seed_rs 40 "$(date +%s)"; run_gate '{}'
assert_contains "$ERR" "since the last human turn" "soft whisper's clock"
seed_rs 80 "$(date +%s)"; run_gate '{}'
assert_contains "$ERR" "since the last human turn" "hard whisper's clock"
assert_not_contains "$ERR" "John" "no one person named in a published whisper"

# ── Per-agent counters ─────────────────────────────────────────────────────
# Inside a subagent the harness stamps `agent_id` (and `agent_type`) on every tool hook's
# stdin; the main thread carries neither, and only the main thread ever receives a
# UserPromptSubmit. Before this, every agent under a project dir ticked ONE counter that
# only a human prompt could reset, so an overnight fleet pooled its calls to the ceiling
# and every worker was blocked together (the 2026-09-07 strand, reported 2026-09-14).
sub_input() { printf '{"agent_id":"%s","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"ls"}}' "$1"; }
sub_tick() { sub_input "$1" | bash "$GOV" tick; }
sub_gate() { ERR="$(sub_input "$1" | bash "$GOV" gate 2>&1 >/dev/null)"; RC=$?; }

test_start "a subagent's tick counts under its own agent_id, not the main counter"
printf '{}\n' > "$(care_path)"
sub_tick a1; sub_tick a1; sub_tick a1
assert_eq "$(read_care '.run_agents["a1"].actions_since_human')" "3" "agent a1 counted"
assert_eq "$(read_care '.run_state.actions_since_human // "untouched"')" "untouched" "main counter untouched"

test_start "a subagent's first tick stamps its own clock"
[ "$(read_care '.run_agents["a1"].last_human_ts')" -gt 0 ] 2>/dev/null
assert_exit "$?" "0" "agent clock set"

test_start "the fleet shape: ten agents at eight calls each all pass the gate"
printf '{}\n' > "$(care_path)"
for a in f1 f2 f3 f4 f5 f6 f7 f8 f9 f10; do for _i in 1 2 3 4 5 6 7 8; do sub_tick "$a"; done; done
worst=0; for a in f1 f2 f3 f4 f5 f6 f7 f8 f9 f10; do sub_gate "$a"; [ "$RC" -gt "$worst" ] && worst=$RC; done
assert_eq "$worst" "0" "no agent blocked at 80 pooled / 8 each"

test_start "a subagent at its own ceiling is paused on its own count"
NOW=$(date +%s)
printf '{"run_agents":{"big":{"actions_since_human":80,"last_human_ts":%s,"soft_warned":false}}}\n' "$NOW" > "$(care_path)"
sub_gate big
assert_exit "$RC" "2" "own ceiling pauses"
assert_contains "$ERR" "agent big" "names the agent"

test_start "a subagent's pause tells it what it CAN do (it has no human to turn to)"
assert_contains "$ERR" "finish and report" "subagent-actionable message"
assert_not_contains "$ERR" "Take a turn with your human" "not the main-thread instruction"

test_start "the main thread at its ceiling does not pause a fresh subagent"
seed_rs 80 "$(date +%s)"
sub_gate fresh
assert_exit "$RC" "0" "main's count is not the agent's"

test_start "a subagent at its ceiling does not pause the main thread"
printf '{"run_state":{"actions_since_human":1,"last_human_ts":%s,"soft_warned":false},"run_agents":{"big":{"actions_since_human":80,"last_human_ts":%s,"soft_warned":false}}}\n' "$NOW" "$NOW" > "$(care_path)"
run_gate '{}'
assert_exit "$RC" "0" "agent's count is not main's"

test_start "a human turn (reset) clears every agent counter"
bash "$GOV" reset
assert_eq "$(read_care '.run_agents // "gone" | if type=="object" then (keys|length) else . end')" "0" "run_agents emptied"

test_start "a live stand-down token covers subagents too"
printf '{"run_agents":{"big":{"actions_since_human":80,"last_human_ts":%s,"soft_warned":false}},"gate_cleared":{"run-governor":{"until":%s}}}\n' "$NOW" "$((NOW+600))" > "$(care_path)"
sub_gate big
assert_exit "$RC" "0" "token stands the agent down"

print_summary
teardown_test_env
exit $FAILED
