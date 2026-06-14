#!/usr/bin/env bash
# Tests for hooks/scripts/maude-drift-watch.sh — repeated-tool-call detection.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

DRIFT="$HOOKS_DIR/maude-drift-watch.sh"
TODAY="$(date +%Y-%m-%d)"

run_drift() {
  ERR="$(printf '{"prompt":"hi"}' | bash "$DRIFT" 2>&1 >/dev/null)"
  RC=$?
}

# Always exits 0
test_start "drift exits 0 with no trace file"
run_drift
assert_exit "$RC" "0" "no trace exit"

test_start "drift silent with no trace"
assert_eq "$ERR" "" "silent"

# Seed trace with synthetic events
seed_trace() {
  : > "$(trace_path)"
  for ((i=0; i<"$1"; i++)); do
    if [ -n "${3:-}" ]; then
      jq -nc --arg ts "2026-05-08T12:00:0${i}Z" --arg t "$2" --arg target "$3" \
        '{ts:$ts, kind:"tool", tool:$t, target:$target}' \
        >> "$(trace_path)"
    else
      jq -nc --arg ts "2026-05-08T12:00:0${i}Z" --arg t "$2" \
        '{ts:$ts, kind:"tool", tool:$t}' \
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
assert_eq "$(read_care '.drift_warned.grep')" "$TODAY" "cooldown persisted after heal"

# ── v0.5.6: read_targets prunes STALE-dated keys (no unbounded growth in care.json) ──
# The cooldown only cares about TODAY's date, so yesterday's keys are pure cruft; a
# write must drop them, not just append. Seed a stale entry + a same-day entry, then
# fire a new read-drift: stale gone, today's kept, new recorded.
clear_traces
jq -nc --arg today "$TODAY" \
  '{drift_warned:{read_targets:{"/old/stale.py":"2020-01-01","/today/kept.py":$today}}}' \
  > "$(care_path)"
seed_trace 4 "Read" "/p/newfile.md"
run_drift

test_start "drift records the newly over-read target"
assert_ne "$(read_care '.drift_warned.read_targets["/p/newfile.md"]')" "null" "new target recorded"

test_start "drift prunes a stale-dated read_targets entry (no unbounded growth)"
assert_eq "$(read_care '.drift_warned.read_targets["/old/stale.py"]')" "null" "stale entry pruned"

test_start "drift keeps a same-day read_targets entry (prune is date-scoped)"
assert_eq "$(read_care '.drift_warned.read_targets["/today/kept.py"]')" "$TODAY" "today entry kept"

print_summary
teardown_test_env
exit $FAILED
