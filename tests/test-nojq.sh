#!/usr/bin/env bash
# Tests for the jq-ABSENT degradation path. The plugin promises to "degrade
# gracefully" without jq, but until now NO test exercised that branch (and the
# jq-backed lib helpers mask it). Every hook must still exit 0 (never crash,
# never block) without jq, and the trace must still write a valid minimal line.
#
# This file deliberately AVOIDS the jq-backed helpers (read_care / count_trace_lines)
# — they return null/0 without jq and would hide regressions. It parses with grep/sed.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

NOJQ="$(make_nojq_bin)"

# Sanity: under the stub PATH, jq really is gone (otherwise every assertion lies).
test_start "stub PATH genuinely hides jq"
PATH="$NOJQ" command -v jq >/dev/null 2>&1
assert_exit "$?" "1" "jq absent under stub"

# Every hook must exit 0 (graceful) without jq — fed a benign envelope on stdin.
# (The gate's fail-open is asserted separately below with a would-be-blocked cmd.)
for hook in maude-session-start maude-care maude-bash-watch maude-drift-watch \
            maude-pre-tool-use maude-post-tool-use maude-probe-tier1 \
            maude-trace maude-user-prompt-submit maude-session-stop \
            maude-subagent-stop maude-pre-compact; do
  test_start "hook $hook exits 0 without jq"
  printf '{}' | PATH="$NOJQ" bash "$HOOKS_DIR/$hook.sh" >/dev/null 2>&1
  assert_exit "$?" "0" "$hook no-jq exit"
done

# The gate fails OPEN without jq (documented contract) — never crash, never block.
test_start "gate exits 0 (fail-open) on a block-worthy command without jq"
make_bash_tool_input "git push origin main --force" | PATH="$NOJQ" bash "$HOOKS_DIR/maude-gate.sh" >/dev/null 2>&1
assert_exit "$?" "0" "gate no-jq exit"

# Trace must still write a parseable minimal JSONL line without jq.
test_start "trace writes a record without jq"
printf '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | PATH="$NOJQ" bash "$HOOKS_DIR/maude-trace.sh" event >/dev/null 2>&1
assert_file_exists "$(trace_path)" "trace file written without jq"

test_start "no-jq trace line carries ts and kind (parsed without jq)"
LINE="$(tail -1 "$(trace_path)" 2>/dev/null)"
# Validate shape with grep, NOT jq — must be {"ts":"...Z","kind":"event"}
printf '%s' "$LINE" | grep -qE '^\{"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z","kind":"event"\}$'
assert_exit "$?" "0" "minimal JSONL shape: $LINE"

# SessionStart still emits the one-time jq-missing safety notice without jq.
test_start "session-start still surfaces the jq-missing notice without jq"
NOTICE="$(printf '{}' | PATH="$NOJQ" bash "$HOOKS_DIR/maude-session-start.sh" 2>&1 >/dev/null)"
assert_contains "$NOTICE" "jq" "notice present under no-jq"

# The no-jq care fallback writes valid content (its own 5 fields) — a malformed
# printf in that branch would otherwise pass unnoticed (exit 0 only).
test_start "care no-jq fallback writes its own fields as parseable JSON"
printf '{}' | PATH="$NOJQ" bash "$HOOKS_DIR/maude-care.sh" >/dev/null 2>&1
CARE_OUT="$(cat "$(care_path)" 2>/dev/null)"
assert_contains "$CARE_OUT" '"last_date"' "last_date key written"
test_start "care no-jq fallback output is valid JSON"
jq -e . "$(care_path)" >/dev/null 2>&1   # parent shell HAS jq; validate the bytes the no-jq branch wrote
assert_exit "$?" "0" "no-jq care.json parses"

print_summary
teardown_test_env
exit $FAILED
