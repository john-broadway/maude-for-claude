#!/usr/bin/env bash
# Tests for hooks/scripts/maude-trace.sh — metadata-only event audit.
# v0.1.5 reshape: must NOT capture tool_input.content, tool_response, bash command body.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

TRACE_HOOK="$HOOKS_DIR/maude-trace.sh"

test_start "trace exits 0 on empty stdin"
RC="$(printf '' | bash "$TRACE_HOOK" event >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "empty stdin"

test_start "trace writes file on real input"
INPUT='{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x.md","content":"sensitive"}}'
printf '%s' "$INPUT" | bash "$TRACE_HOOK" event >/dev/null 2>&1
assert_file_exists "$(trace_path)" "trace file"

test_start "trace captures hook_event_name"
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"hook":"PostToolUse"' "hook field"

test_start "trace captures tool name"
assert_contains "$last" '"tool":"Read"' "tool field"

test_start "trace captures file_path target"
assert_contains "$last" '"target":"/x.md"' "target field"

# CRITICAL: leak vectors must be absent
test_start "trace does NOT capture tool_input.content"
assert_not_contains "$last" "sensitive" "content NOT captured"

test_start "trace does NOT capture full tool_input object"
assert_not_contains "$last" '"content":' "content key absent"

# Bash command body
INPUT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo secret token xyz"}}'
: > "$(trace_path)"
printf '%s' "$INPUT" | bash "$TRACE_HOOK" event >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"

test_start "trace does NOT capture bash command body"
assert_not_contains "$last" "secret" "command body absent"

test_start "trace does NOT capture tool_response"
INPUT='{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":{"content":"file content here"}}'
: > "$(trace_path)"
printf '%s' "$INPUT" | bash "$TRACE_HOOK" event >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_not_contains "$last" "file content here" "response absent"

test_start "trace kind defaults to 'event'"
assert_contains "$last" '"kind":"event"' "default kind"

test_start "trace honors explicit kind argument"
INPUT='{"hook_event_name":"X","tool_name":"Y"}'
: > "$(trace_path)"
printf '%s' "$INPUT" | bash "$TRACE_HOOK" tool >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"kind":"tool"' "explicit kind"

print_summary
teardown_test_env
exit $FAILED
