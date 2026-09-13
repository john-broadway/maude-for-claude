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

# ── Session tie (fleet fix): every entry says which session produced it ──
test_start "trace records the session label"
INPUT='{"hook_event_name":"PostToolUse","tool_name":"Grep","session_id":"abcd1234-9999-8888"}'
: > "$(trace_path)"
printf '%s' "$INPUT" | MAUDE_SESSION_LABEL=pacioli bash "$TRACE_HOOK" tool >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"session":"pacioli"' "session label on entry"

test_start "trace records the harness session id (short)"
assert_contains "$last" '"sid":"abcd1234"' "sid prefix on entry"

test_start "trace without any session identity labels solo"
INPUT='{"hook_event_name":"PostToolUse","tool_name":"Grep"}'
: > "$(trace_path)"
printf '%s' "$INPUT" | bash "$TRACE_HOOK" tool >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"session":"solo"' "solo fallback"

test_start "trace with only a session_id labels by its prefix"
INPUT='{"hook_event_name":"PostToolUse","tool_name":"Grep","session_id":"feed0042-1111"}'
: > "$(trace_path)"
printf '%s' "$INPUT" | bash "$TRACE_HOOK" tool >/dev/null 2>&1
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"session":"feed0042"' "sid-prefix label"


# The gate's token is spent at PostToolUse of the command that RAN (see test-gate.sh); this
# hook is the PostToolUse entry that sees every Bash completion, so it is the caller.
test_start "a Bash PostToolUse through the trace hook consumes a reserved gate token"
mkdir -p "$TEST_TMP/.maude/plugin"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"default","at":%d}}}}\n' $(($(date +%s) + 600)) "$(date +%s)" > "$(care_path)"
printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main"},"tool_response":{"stdout":"","stderr":"","interrupted":false}}' | bash "$TRACE_HOOK" tool >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "token spent by the run"

test_start "a PreToolUse Bash through the trace hook does NOT consume"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"default","at":%d}}}}\n' $(($(date +%s) + 600)) "$(date +%s)" > "$(care_path)"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | bash "$TRACE_HOOK" event >/dev/null 2>&1
assert_ne "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "token untouched at Pre"
rm -f "$(care_path)"

# The consume is gated so the gate's pattern walk stays off every Bash completion, and the
# gate itself exits before that walk unless a token can actually be spent by THIS call (the
# 25th lens, IMPORTANT-1: the first guard was a text grep for "reserved", defeated for the
# whole life of an orphaned reservation and by the word appearing anywhere in a 34 KB
# shared file; MINOR-6: it also made an unreserved live token unspendable).
test_start "a LIVE token nobody reserved is still spent by the command that ran (25th lens, MINOR-6)"
mkdir -p "$TEST_TMP/.maude/plugin"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$TEST_TMP/.maude/plugin/care.json"
make_bash_tool_input "git push origin main" | jq -c '. + {hook_event_name:"PostToolUse", tool_response:{stdout:"",stderr:"",interrupted:false}}' | bash "$TRACE_HOOK" >/dev/null 2>&1
assert_eq "$(jq -r '.gate_cleared["git-push"].until // "absent"' "$TEST_TMP/.maude/plugin/care.json")" "absent" "the unreserved token is spent"

test_start "an ORPHANED reservation for ANOTHER call does not put the gate's pattern walk back on every completion"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"other000","at":%d,"fp":"999999999","head":"git push origin other","v":2}}}}\n' $(($(date +%s) + 600)) $(($(date +%s) - 400)) > "$TEST_TMP/.maude/plugin/care.json"
T0=$(date +%s%N)
for _i in 1 2 3 4 5; do make_bash_tool_input "ls -la /tmp" | jq -c '. + {hook_event_name:"PostToolUse", tool_response:{stdout:"",stderr:"",interrupted:false}}' | bash "$TRACE_HOOK" >/dev/null 2>&1; done
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 5000000 ))
[ "$MS" -lt 150 ]
assert_exit "$?" "0" "an unrelated completion costs ${MS} ms, under 150"
assert_ne "$(jq -r '.gate_cleared["git-push"].until // "absent"' "$TEST_TMP/.maude/plugin/care.json")" "absent" "and the other call's reservation is untouched"
rm -f "$TEST_TMP/.maude/plugin/care.json"

print_summary
teardown_test_env
exit $FAILED
