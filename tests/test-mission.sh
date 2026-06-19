#!/usr/bin/env bash
# Tests for hooks/scripts/maude-mission.sh — the mission-hold rail.
#
# One pin (.mission in care.json), four touches:
#   capture  — pin the mission from an ExitPlanMode plan / TodoWrite list (mission-level, sticky)
#   hold     — inject the MISSION line every UserPromptSubmit (the anti-fade)
#   verify   — whisper at the action-flip (first Write/Edit/Bash after talking), naming the mission
#   clear    — wipe the pin (SessionStart; fresh each session)

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

MISSION="$HOOKS_DIR/maude-mission.sh"

reset_care()  { printf '{}\n' > "$(care_path)"; }
reset_trace() { : > "$(trace_path)"; }

exitplan_input() {  # $1 = plan text
  jq -nc --arg p "$1" '{tool_name:"ExitPlanMode", tool_input:{plan:$p}, hook_event_name:"PostToolUse"}'
}
todo_input() {  # a completed + an in-progress item; the in-progress one is the mission
  jq -nc '{tool_name:"TodoWrite", tool_input:{todos:[
    {content:"Write the tests", status:"completed", activeForm:"Writing the tests"},
    {content:"Implement capture", status:"in_progress", activeForm:"Implementing capture"}
  ]}, hook_event_name:"PostToolUse"}'
}
action_input() {  # $1 = tool name (Write/Edit/Bash)
  jq -nc --arg t "$1" '{tool_name:$t, tool_input:{}, hook_event_name:"PreToolUse"}'
}
seed_prompt() { jq -nc '{ts:"2026-06-18T12:00:00Z", kind:"prompt"}' >> "$(trace_path)"; }
seed_tool()   { jq -nc --arg t "$1" '{ts:"2026-06-18T12:00:05Z", kind:"tool", tool:$t}' >> "$(trace_path)"; }

# ── CAPTURE ──────────────────────────────────────────────────────────────
test_start "capture pins the first line of an ExitPlanMode plan"
reset_care
exitplan_input "Build the mission-hold rail
Then trim the commands." | bash "$MISSION" capture
assert_eq "$(read_care '.mission.text')" "Build the mission-hold rail" "plan first line pinned"

test_start "capture pins the in-progress TodoWrite item"
reset_care
todo_input | bash "$MISSION" capture
assert_eq "$(read_care '.mission.text')" "Implement capture" "active todo pinned"

test_start "capture is a no-op for a tool with no plan/todos (stays unpinned)"
reset_care
action_input "Write" | bash "$MISSION" capture
assert_eq "$(read_care '.mission.text')" "null" "no pin from a Write"

# ── HOLD ─────────────────────────────────────────────────────────────────
test_start "hold injects the MISSION line when a pin is set"
reset_care
exitplan_input "Ship the rail" | bash "$MISSION" capture
ERR="$(printf '{"prompt":"next"}' | bash "$MISSION" hold 2>&1 >/dev/null)"
assert_contains "$ERR" "MISSION:" "mission line injected"
assert_contains "$ERR" "Ship the rail" "names the mission"

test_start "hold is silent when no mission is pinned"
reset_care
ERR="$(printf '{"prompt":"next"}' | bash "$MISSION" hold 2>&1 >/dev/null)"
assert_eq "$ERR" "" "silent without a pin"

# ── VERIFY (the action-flip catch) ───────────────────────────────────────
test_start "verify whispers on the first action after the prompt, naming the mission"
reset_care; reset_trace
exitplan_input "Ship the rail" | bash "$MISSION" capture
seed_prompt   # talked; no action yet this turn
ERR="$(action_input Write | bash "$MISSION" verify 2>&1 >/dev/null)"
assert_contains "$ERR" "Ship the rail" "verify names the mission at the flip"

test_start "verify is silent once already acting this turn (mid-streak)"
reset_care; reset_trace
exitplan_input "Ship the rail" | bash "$MISSION" capture
seed_prompt
seed_tool "Write"   # an action already happened since the prompt
ERR="$(action_input Edit | bash "$MISSION" verify 2>&1 >/dev/null)"
assert_eq "$ERR" "" "silent once already acting"

test_start "verify with no pin asks what you are doing (fallback capture-prompt)"
reset_care; reset_trace
seed_prompt
ERR="$(action_input Write | bash "$MISSION" verify 2>&1 >/dev/null)"
assert_contains "$ERR" "No mission" "fallback prompt when unpinned"

# ── CLEAR ────────────────────────────────────────────────────────────────
test_start "clear wipes the pinned mission"
reset_care
exitplan_input "Ship the rail" | bash "$MISSION" capture
bash "$MISSION" clear < /dev/null
assert_eq "$(read_care '.mission.text')" "null" "mission cleared"

# ── never blocks ─────────────────────────────────────────────────────────
test_start "verify exits 0 (whisper, never block)"
action_input Write | bash "$MISSION" verify >/dev/null 2>&1
assert_exit "$?" "0" "verify exit 0"

print_summary
teardown_test_env
exit $FAILED
