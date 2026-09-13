#!/usr/bin/env bash
# Tests for hooks/scripts/maude-subagent-stop.sh — subagent end logging.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

SUB="$HOOKS_DIR/maude-subagent-stop.sh"

test_start "subagent-stop exits 0"
RC="$(printf '{"subagent_type":"test"}' | bash "$SUB" >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "exit"

test_start "subagent-stop logs subagent-stop event"
n="$(count_trace_lines '.kind == "subagent-stop"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

test_start "subagent-stop captures agent name"
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" "agent=test" "agent recorded"

test_start "subagent-stop handles missing agent field"
: > "$(trace_path)"
RC="$(printf '{}' | bash "$SUB" >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "exit on missing field"

last="$(tail -1 "$(trace_path)")"
test_start "subagent-stop records 'unknown' when field missing"
assert_contains "$last" "agent=unknown" "fallback name"


# The harness's SubagentStop stdin carries agent_id and agent_type (hooks reference); the
# id is what ties a stop back to the launch that is waiting on it. Log both, id shortened.
test_start "subagent-stop records agent_type and the agent id from the harness's own fields"
: > "$(trace_path)"
printf '{"hook_event_name":"SubagentStop","agent_id":"a7f93cda58bbfd3cf","agent_type":"general-purpose"}' | bash "$SUB" >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" "agent=general-purpose" "agent_type recorded"
assert_contains "$last" "id=a7f93cda" "agent id recorded (8 chars)"

print_summary
teardown_test_env
exit $FAILED
