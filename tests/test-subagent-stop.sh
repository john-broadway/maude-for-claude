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

print_summary
teardown_test_env
exit $FAILED
