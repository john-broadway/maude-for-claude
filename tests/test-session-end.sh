#!/usr/bin/env bash
# Tests for hooks/scripts/maude-session-end.sh — the true session-end stitch.
#
# SessionEnd is a REAL end (exit/logout/clear), unlike Stop which fires every
# assistant pause — so here, and only here, an auto-note is safe. The hook:
#   1. always logs a session-end trace event (with the reason),
#   2. stamps care.json .last_session_end,
#   3. if the session leaves 3+ uncaptured exchanges AND the handoff slot
#      (.remember/remember.md) is empty/absent, writes a one-line auto-note
#      pointing the next session at the trace.
# It must NEVER overwrite a non-empty handoff (a fresh /maude:rest write).

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

HOOK="$HOOKS_DIR/maude-session-end.sh"
REMEMBER="$TEST_TMP/.remember"
HANDOFF="$REMEMBER/remember.md"
TRACE="$TEST_TMP/.maude/plugin/trace/today-2026-06-23.jsonl"

emit_prompt() {  # emit_prompt <ts>
  jq -nc --arg ts "$1" '{ts:$ts,kind:"prompt",hook:"UserPromptSubmit"}' >> "$TRACE"
}
run_hook() {  # run_hook [reason]
  jq -nc --arg r "${1:-exit}" '{reason:$r, hook_event_name:"SessionEnd"}' | bash "$HOOK" >/dev/null 2>&1
  RC=$?
}

# ── Always: trace + stamp ──────────────────────────────────────────────

run_hook "logout"

test_start "logs a session-end trace event with the reason"
LINE="$(grep '"kind":"session-end"' "$(trace_path)" | head -1)"
assert_contains "$LINE" "reason=logout" "trace"

test_start "stamps care.json last_session_end"
assert_ne "$(read_care '.last_session_end // ""')" "" "stamp present"

test_start "always exits 0"
assert_exit "$RC" "0" "exit"

# ── Auto-note: uncaptured session + empty handoff slot ─────────────────

mkdir -p "$REMEMBER"
: > "$TRACE"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
rm -f "$HANDOFF"
run_hook "exit"

test_start "writes an auto-note when 3+ exchanges are uncaptured and the slot is empty"
assert_file_exists "$HANDOFF" "auto-note written"

test_start "the auto-note points the next session at the trace"
assert_contains "$(cat "$HANDOFF" 2>/dev/null)" "/maude:wake" "reconstruct pointer"

test_start "the auto-note names the count of uncaptured exchanges"
assert_contains "$(cat "$HANDOFF" 2>/dev/null)" "3" "count"

test_start "the auto-note says it is an auto-note, not a real handoff"
assert_contains "$(cat "$HANDOFF" 2>/dev/null)" "Auto-note from Maude" "honest label"

# ── Never clobber a fresh handoff ──────────────────────────────────────

printf '# Handoff\n\n## Next\n- the real thread\n' > "$HANDOFF"
touch_at "2026-06-23T23:00:00Z" "$HANDOFF"
run_hook "exit"

test_start "a non-empty handoff is never overwritten"
assert_contains "$(cat "$HANDOFF")" "the real thread" "content preserved"

# ── Silent cases ───────────────────────────────────────────────────────

: > "$TRACE"
emit_prompt "2026-06-24T10:00:00Z"
emit_prompt "2026-06-24T11:00:00Z"
rm -f "$HANDOFF"
run_hook "exit"

test_start "below threshold (2 exchanges) → no auto-note"
assert_file_absent "$HANDOFF" "no note"

rm -rf "$REMEMBER"
: > "$TRACE"
emit_prompt "2026-06-24T12:00:00Z"
emit_prompt "2026-06-24T13:00:00Z"
emit_prompt "2026-06-24T14:00:00Z"
run_hook "exit"

test_start "no .remember dir → no auto-note, no dir created"
assert_file_absent "$REMEMBER" "remember dir untouched"

# ── Degraded: no jq ────────────────────────────────────────────────────

test_start "no jq → still exits 0"
NOJQ_BIN="$(make_nojq_bin)"
printf '{"reason":"exit"}' | PATH="$NOJQ_BIN" bash "$HOOK" >/dev/null 2>&1
assert_exit "$?" "0" "exit"

test_start "no jq → trace event still written (fallback writer)"
COUNT_BEFORE="$(grep -c '"kind":"session-end"' "$(trace_path)")"
printf '{"reason":"exit"}' | PATH="$NOJQ_BIN" bash "$HOOK" >/dev/null 2>&1
COUNT_AFTER="$(grep -c '"kind":"session-end"' "$(trace_path)")"
assert_ne "$COUNT_AFTER" "$COUNT_BEFORE" "trace grew"

teardown_test_env
print_summary
