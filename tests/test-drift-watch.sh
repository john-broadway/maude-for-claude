#!/usr/bin/env bash
# Tests for hooks/scripts/maude-drift-watch.sh — repeated-tool-call detection.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

DRIFT="$HOOKS_DIR/maude-drift-watch.sh"
TODAY="$(date +%Y-%m-%d)"

run_drift() {  # run_drift [session-label] — empty label resolves to "solo"
  ERR="$(printf '{"prompt":"hi"}' | MAUDE_SESSION_LABEL="${1:-}" bash "$DRIFT" 2>&1 >/dev/null)"
  RC=$?
}

# Always exits 0
test_start "drift exits 0 with no trace file"
run_drift
assert_exit "$RC" "0" "no trace exit"

test_start "drift silent with no trace"
assert_eq "$ERR" "" "silent"

# Seed trace with synthetic events. 4th arg = session label (default "solo",
# matching what run_drift resolves to when no label is passed). Drift-watch
# scopes to the CURRENT session's events, so seeds must say whose they are.
seed_trace() {
  : > "$(trace_path)"
  append_trace "$@"
}
append_trace() {  # append_trace <n> <tool> <target> [session]
  for ((i=0; i<"$1"; i++)); do
    if [ -n "${3:-}" ]; then
      jq -nc --arg ts "2026-05-08T12:00:0${i}Z" --arg t "$2" --arg target "$3" --arg s "${4:-solo}" \
        '{ts:$ts, kind:"tool", tool:$t, target:$target, session:$s}' \
        >> "$(trace_path)"
    else
      jq -nc --arg ts "2026-05-08T12:00:0${i}Z" --arg t "$2" --arg s "${4:-solo}" \
        '{ts:$ts, kind:"tool", tool:$t, session:$s}' \
        >> "$(trace_path)"
    fi
  done
}

test_start "drift fires on Grep hammering"
seed_trace 5 "Grep" ""
run_drift
assert_contains "$ERR" "grepping" "grep warning"

test_start "drift cooldown — second run silent"
run_drift
assert_eq "$ERR" "" "cooldown holds"

test_start "drift logs trace event"
n="$(count_trace_lines '.kind == "drift"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

# Reset for read-target test
: > "$(care_path)"
seed_trace 4 "Read" "/some/file.md"
test_start "drift fires on repeated Read of same target"
run_drift
assert_contains "$ERR" "Read file.md" "read warning"

test_start "drift read-target cooldown"
run_drift
assert_eq "$ERR" "" "read cooldown"

# Below threshold — silent
: > "$(care_path)"
seed_trace 2 "Grep" ""
test_start "drift silent below threshold"
run_drift
assert_eq "$ERR" "" "below threshold"

# ── R2-adjacent: a corrupt care.json must not FREEZE the cooldown write ──
# drift-watch used to only seed-if-EMPTY, so a corrupt (non-empty) care.json made
# its merge silently fail — the whisper could never remember it fired. Routing init
# through maude_care_ensure heals it (and records the loss), so the cooldown persists.
seed_trace 5 "Grep" ""
printf 'not valid json {{{\n' > "$(care_path)"
test_start "drift heals a corrupt care.json and persists its cooldown (no freeze)"
run_drift
assert_eq "$(read_care '.drift_warned.solo.grep')" "$TODAY" "cooldown persisted after heal"

# ── v0.5.6: read_targets prunes STALE-dated keys (no unbounded growth in care.json) ──
# The cooldown only cares about TODAY's date, so yesterday's keys are pure cruft; a
# write must drop them, not just append. Seed a stale entry + a same-day entry, then
# fire a new read-drift: stale gone, today's kept, new recorded.
clear_traces
jq -nc --arg today "$TODAY" \
  '{drift_warned:{solo:{read_targets:{"/old/stale.py":"2020-01-01","/today/kept.py":$today}}}}' \
  > "$(care_path)"
seed_trace 4 "Read" "/p/newfile.md"
run_drift

test_start "drift records the newly over-read target"
assert_ne "$(read_care '.drift_warned.solo.read_targets["/p/newfile.md"]')" "null" "new target recorded"

test_start "drift prunes a stale-dated read_targets entry (no unbounded growth)"
assert_eq "$(read_care '.drift_warned.solo.read_targets["/old/stale.py"]')" "null" "stale entry pruned"

test_start "drift keeps a same-day read_targets entry (prune is date-scoped)"
assert_eq "$(read_care '.drift_warned.solo.read_targets["/today/kept.py"]')" "$TODAY" "today entry kept"

# ── Session tie (the fleet fix): commentary scopes to the session it watched ──
# Three concurrent sessions share one trace file. A whisper that says "Claude is
# stuck grepping" must be about THIS session's Claude, not a neighbor's.
: > "$(care_path)"
seed_trace 6 "Grep" "" "pacioli"
test_start "drift IGNORES another session's grep hammering"
run_drift "hub"
assert_eq "$ERR" "" "no cross-session whisper"

test_start "drift fires on OWN-session events interleaved with a neighbor's"
append_trace 5 "Grep" "" "hub"
run_drift "hub"
assert_contains "$ERR" "grepping 5 times" "own events counted, neighbor's excluded"

test_start "drift cooldown is per-session (hub's whisper does not mute pacioli's)"
run_drift "pacioli"
assert_contains "$ERR" "grepping 6 times" "pacioli still gets its own whisper"

test_start "drift entries with no session label do not count toward a labeled session"
: > "$(care_path)"
: > "$(trace_path)"
for ((i=0; i<6; i++)); do
  jq -nc --arg ts "2026-05-08T12:00:0${i}Z" '{ts:$ts, kind:"tool", tool:"Grep"}' >> "$(trace_path)"
done
run_drift "hub"
assert_eq "$ERR" "" "unlabeled legacy entries excluded"

# ── End-to-end: the REAL writer and the REAL reader must resolve the same
# label. Entries go in through maude-trace.sh with only an envelope session_id
# (no tmux, no override, no env — a plain non-tmux session), and drift-watch
# is invoked with the same envelope. Synthetic seeds bypass the writer and
# once hid a writer/reader label divergence that killed drift-watch for every
# non-tmux session; this closes that gap.
test_start "drift fires end-to-end through the real trace writer (envelope sid only)"
: > "$(care_path)"
: > "$(trace_path)"
for ((i=0; i<5; i++)); do
  printf '{"hook_event_name":"PostToolUse","tool_name":"Grep","session_id":"cafe0042-aaaa-bbbb"}' \
    | bash "$HOOKS_DIR/maude-trace.sh" tool >/dev/null 2>&1
done
ERR="$(printf '{"prompt":"hi","session_id":"cafe0042-aaaa-bbbb"}' | bash "$DRIFT" 2>&1 >/dev/null)"
assert_contains "$ERR" "grepping 5 times" "writer and reader agree on the label"

test_start "drift stays scoped end-to-end (a different envelope sid is silent)"
: > "$(care_path)"
ERR="$(printf '{"prompt":"hi","session_id":"09999999-zzzz"}' | bash "$DRIFT" 2>&1 >/dev/null)"
assert_eq "$ERR" "" "another session's envelope sees nothing"

print_summary
teardown_test_env
exit $FAILED
