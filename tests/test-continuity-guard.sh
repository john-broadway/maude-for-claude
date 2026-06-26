#!/usr/bin/env bash
# Tests for maude_continuity_guard (in _maude-common.sh) — the SessionStart loop that
# PROTECTS continuity. It compares the last save (the handoff's mtime) against real
# activity in the trace (user `prompt` events), and warns when work happened AFTER the
# last save — i.e. the handoff is stale and the next session would wake half-blind.
#
# Why it's needed: the Stop hook writes no handoff (it can't detect real session-end),
# so a clean quit without /maude:rest leaves the next session on a stale save, silently.
# This is the closing link the continuity chain was missing. `prompt` is the signal:
# SessionStart fires before this session's first prompt, so every counted prompt is
# genuinely prior, unsaved work.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

REMEMBER="$TEST_TMP/.remember"
HANDOFF="$REMEMBER/remember.md"
TRACE="$TEST_TMP/.maude/plugin/trace/today-2026-06-23.jsonl"

emit_prompt() {  # emit_prompt <ts>
  jq -nc --arg ts "$1" '{ts:$ts,kind:"prompt",hook:"UserPromptSubmit"}' >> "$TRACE"
}
reset_trace() { : > "$TRACE"; }
make_handoff_at() {  # make_handoff_at <iso-mtime>
  mkdir -p "$REMEMBER"
  printf '# Handoff\n\n## Next\n- pick up the thread\n' > "$HANDOFF"
  touch -d "$1" "$HANDOFF"
}

# ── Scenario 1: 3+ exchanges ran after the last save → warn (stale handoff) ──
reset_trace
make_handoff_at "2026-06-23T00:00:00Z"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
OUT1="$(maude_continuity_guard)"

test_start "warns when 3+ exchanges ran after the last save"
assert_contains "$OUT1" "may be stale" "stale-handoff warning fired"

test_start "the warning names the count of unsaved exchanges"
assert_contains "$OUT1" "3 exchanges" "count surfaced"

# ── Scenario 2: handoff newer than all activity → silent ──
reset_trace
make_handoff_at "2026-06-23T23:00:00Z"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
OUT2="$(maude_continuity_guard)"

test_start "silent when the handoff is newer than all activity"
assert_eq "$OUT2" "" "fresh handoff → no warning"

# ── Scenario 3: below threshold (the tail of a saved session) → silent ──
reset_trace
make_handoff_at "2026-06-23T00:00:00Z"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
OUT3="$(maude_continuity_guard)"

test_start "silent below the threshold (2 exchanges is not yet a lost session)"
assert_eq "$OUT3" "" "below threshold → no warning"

# ── Scenario 4: no saved handoff at all, but the trace shows real prior work → warn ──
reset_trace
mkdir -p "$REMEMBER"; rm -f "$HANDOFF"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
OUT4="$(maude_continuity_guard)"

test_start "warns when nothing was captured but the trace shows prior work"
assert_contains "$OUT4" "no continuity captured" "no-capture warning fired"

# ── Scenario 5: project has no .remember dir → guard is N/A, silent ──
reset_trace
rm -rf "$REMEMBER"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
OUT5="$(maude_continuity_guard)"

test_start "silent when the project has no .remember dir (guard is N/A)"
assert_eq "$OUT5" "" "no remember dir → no warning"

# ── Scenario 7: remember.md drained empty BUT the live buffer is fresh → silent ──
# The real live-workspace state the dogfood exposed: remember.md is a drained inbox while
# $REMEMBER/now.md stays current. The guard must anchor on the FRESHEST source and NOT
# false-alarm on the empty handoff. (The first cut anchored on remember.md alone and fired
# — this locks the fix.)
reset_trace
mkdir -p "$REMEMBER"; rm -f "$HANDOFF"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
printf '\n## 12:30 | unknown\nfresh live buffer\n' > "$REMEMBER/now.md"
touch -d "2026-06-23T12:30:00Z" "$REMEMBER/now.md"
OUT7="$(maude_continuity_guard)"

test_start "silent when remember.md is drained but the live buffer is fresh (no false alarm)"
assert_eq "$OUT7" "" "anchors on the freshest source, not the empty handoff"

# Same window WITHOUT the fresh buffer DOES warn — proves the buffer is what silenced it.
rm -f "$REMEMBER/now.md"
OUT7B="$(maude_continuity_guard)"
test_start "the same window without a fresh buffer warns (the buffer is what silences it)"
assert_contains "$OUT7B" "no continuity captured" "warns when no fresh source exists"

# ── Scenario 6: the session-start hook surfaces the guard line ──
SS="$HOOKS_DIR/maude-session-start.sh"
reset_trace
make_handoff_at "2026-06-23T00:00:00Z"
emit_prompt "2026-06-23T10:00:00Z"
emit_prompt "2026-06-23T11:00:00Z"
emit_prompt "2026-06-23T12:00:00Z"
OUT6="$(bash "$SS" 2>/dev/null)"

test_start "session-start surfaces the continuity-stale warning"
assert_contains "$OUT6" "may be stale" "guard reaches the brief"

print_summary
teardown_test_env
exit $FAILED
