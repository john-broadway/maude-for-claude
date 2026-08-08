#!/usr/bin/env bash
# Tests for hooks/scripts/maude-mission.sh — the mission-hold rail.
#
# One pin PER SESSION (.missions[<session_id>] in care.json), four touches:
#   capture  — pin the mission from an ExitPlanMode plan / the in_progress task / a
#              TodoWrite list (mission-level, sticky)
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
assert_eq "$(read_care '.missions.default.text')" "Build the mission-hold rail" "plan first line pinned"

test_start "capture pins the in-progress TodoWrite item"
reset_care
todo_input | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Implement capture" "active todo pinned"

test_start "capture is a no-op for a tool with no plan/todos (stays unpinned)"
reset_care
action_input "Write" | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "null" "no pin from a Write"

# ── CAPTURE from the Task tools — the shape THIS harness actually emits ──────
# The rail shipped parsing TodoWrite's payload: an ARRAY at .tool_input.todos,
# each item {content, status, activeForm}. Measured 2026-07-30 across 25 real
# transcripts: TodoWrite 0, TaskCreate 21, TaskUpdate 28. The Task tools send
# something else entirely —
#   TaskCreate {subject, description, activeForm}   flat object, no array, no status
#   TaskUpdate {taskId, status}                     NO TEXT AT ALL
# so `.tool_input.todos // .tool_input.tasks // []` resolved to [], [0] was null,
# TEXT was "" and capture exited silently. ~1600 chances, 4 pins ever, all on the
# day it was built. A hook that fires and parses nothing is not a rail.
#
# The id->subject map comes from TaskCreate's tool_response, which is why TaskUpdate
# can pin text it never carries (its own response has no subject — only success,
# taskId, updatedFields, statusChange).
#
# These payloads are COPIED FROM THE LIVE HOOK, not imagined. The first version of
# this fixture used the string the TRANSCRIPT shows — "Task #N created successfully:
# <subject>" — and the tests went green while the real rail wrote no map at all.
# That prose is the RENDERED tool_result; the hook receives structured data. When a
# fixture and the harness disagree, the fixture is the one that is wrong, and only a
# live run can tell you.
taskcreate_input() {  # $1 = subject, $2 = task id
  jq -nc --arg s "$1" --arg n "$2" \
    '{tool_name:"TaskCreate",
      tool_input:{subject:$s, description:"…", activeForm:("Doing " + $s)},
      tool_response:{task:{id:$n, subject:$s}},
      hook_event_name:"PostToolUse"}'
}
taskupdate_input() {  # $1 = taskId, $2 = status
  jq -nc --arg i "$1" --arg st "$2" \
    '{tool_name:"TaskUpdate", tool_input:{taskId:$i, status:$st},
      tool_response:{success:true, taskId:$i, updatedFields:["status"],
                     statusChange:{from:"pending", to:$st}},
      hook_event_name:"PostToolUse"}'
}

test_start "TaskCreate pins its subject when nothing is pinned yet"
reset_care
taskcreate_input "Build field projection" 1 | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Build field projection" "first TaskCreate pinned"

test_start "TaskUpdate to in_progress pins THAT task's subject"
reset_care
taskcreate_input "Build field projection" 1 | bash "$MISSION" capture
taskcreate_input "Measure token reduction" 2 | bash "$MISSION" capture
taskupdate_input 2 in_progress | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Measure token reduction" "in_progress task pinned"

# Sticky: the pin is the through-line, not the last little thing touched.
test_start "a later TaskCreate does NOT steal the pin from the in-progress task"
reset_care
taskcreate_input "Build field projection" 1 | bash "$MISSION" capture
taskupdate_input 1 in_progress | bash "$MISSION" capture
taskcreate_input "Some small side errand" 2 | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Build field projection" "pin survives a new task"

# Completing a DIFFERENT task than the pinned one. Completing the pinned task would
# re-pin identical text if the status filter were broken, so that version of this
# test passes either way — it asserts nothing about the filter it exists to guard.
test_start "completing another task does NOT move the mission off the pinned one"
reset_care
taskcreate_input "Build field projection" 1 | bash "$MISSION" capture
taskcreate_input "Measure token reduction" 2 | bash "$MISSION" capture
taskupdate_input 1 in_progress | bash "$MISSION" capture
taskupdate_input 2 completed | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Build field projection" "only in_progress moves the pin"

test_start "TaskUpdate for an unknown id leaves the pin alone"
reset_care
taskcreate_input "Build field projection" 1 | bash "$MISSION" capture
taskupdate_input 1 in_progress | bash "$MISSION" capture
taskupdate_input 99 in_progress | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Build field projection" "unknown id is a no-op"

# Task numbers restart per session, so a stale map would pin the WRONG text.
test_start "clear drops the task map, not just the pin"
reset_care
taskcreate_input "Old session task" 1 | bash "$MISSION" capture
bash "$MISSION" clear < /dev/null
taskupdate_input 1 in_progress | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "null" "no resurrection from a stale map"

# ── THE PIN IS PER SESSION, NOT PER PROJECT ─────────────────────────────────
# care.json is ONE file shared by every session at a project root. While the rail was
# inert this never showed; the moment it fired (2026-07-30) a sibling session started
# receiving this session's mission — three misfires reported in one hour, including
# "design UNDO pillar, get approval first" surfacing in a lane doing proximo work.
# A rail that cries wolf is one you learn to skim, which costs you the times it is
# right. Task IDs restart per session too, so an unscoped map lets session B's task #5
# overwrite session A's — measured, both sessions' checklists collided in one map.
sess_taskcreate() {  # $1 = session id, $2 = subject, $3 = task id
  jq -nc --arg s "$2" --arg n "$3" --arg sid "$1" \
    '{tool_name:"TaskCreate", session_id:$sid,
      tool_input:{subject:$s, description:"…", activeForm:("Doing " + $s)},
      tool_response:{task:{id:$n, subject:$s}}, hook_event_name:"PostToolUse"}'
}
sess_hold() { jq -nc --arg sid "$1" '{prompt:"next", session_id:$sid}'; }

test_start "hold shows a session ONLY its own mission"
reset_care
sess_taskcreate "sess-A" "Port the undo pillar" 1 | bash "$MISSION" capture
ERR_B="$(sess_hold "sess-B" | bash "$MISSION" hold 2>&1 >/dev/null)"
assert_not_contains "$ERR_B" "Port the undo pillar" "sibling session does not see it"

test_start "…while the owning session still sees it"
ERR_A="$(sess_hold "sess-A" | bash "$MISSION" hold 2>&1 >/dev/null)"
assert_contains "$ERR_A" "Port the undo pillar" "owner still gets its mission"

test_start "two sessions hold two different missions at once"
sess_taskcreate "sess-B" "Ship the proximo story" 1 | bash "$MISSION" capture
assert_contains "$(sess_hold "sess-B" | bash "$MISSION" hold 2>&1 >/dev/null)" "Ship the proximo story" "B has its own"

test_start "…and A's mission survived B setting one"
assert_contains "$(sess_hold "sess-A" | bash "$MISSION" hold 2>&1 >/dev/null)" "Port the undo pillar" "A unchanged"

test_start "colliding task IDs across sessions do not cross-resolve"
# Both sessions created a task #1. B flipping ITS #1 must not pin A's subject.
jq -nc '{tool_name:"TaskUpdate", session_id:"sess-B", tool_input:{taskId:"1", status:"in_progress"},
         tool_response:{success:true}, hook_event_name:"PostToolUse"}' | bash "$MISSION" capture
assert_contains "$(sess_hold "sess-B" | bash "$MISSION" hold 2>&1 >/dev/null)" "Ship the proximo story" "B resolved B's task"

test_start "clear wipes only the calling session's pin"
jq -nc '{session_id:"sess-A"}' | bash "$MISSION" clear
assert_contains "$(sess_hold "sess-B" | bash "$MISSION" hold 2>&1 >/dev/null)" "Ship the proximo story" "B survives A's clear"

test_start "TodoWrite still works (other harnesses emit it)"
reset_care
todo_input | bash "$MISSION" capture
assert_eq "$(read_care '.missions.default.text')" "Implement capture" "TodoWrite unregressed"

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
assert_eq "$(read_care '.missions.default.text')" "null" "mission cleared"

# ── never blocks ─────────────────────────────────────────────────────────
test_start "verify exits 0 (whisper, never block)"
action_input Write | bash "$MISSION" verify >/dev/null 2>&1
assert_exit "$?" "0" "verify exit 0"

print_summary
teardown_test_env
exit $FAILED
