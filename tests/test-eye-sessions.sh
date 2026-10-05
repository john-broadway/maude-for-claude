#!/usr/bin/env bash
# The eye is per SESSION: its counter, its spawn lock, its whisper.
#
# Earned 2026-09-25: five sessions on one box shared one eye-state and one eye-whisper.txt,
# so a whisper born from one lane's transcript reached whichever lane prompted next. A
# fresh session, zero tool calls, was told "the last two bash calls appear identical";
# another was told it was "polling the lens status repeatedly". Both were a neighbour's.
# Driven end to end: the real tick spawns the real blink (stub runner), and the whisper it
# writes must reach its own session and no other.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

setup_test_env
WORK="$TEST_TMP"
mkdir -p "$WORK/proj/.maude/plugin"
export MAUDE_PROJECT_DIR_OVERRIDE="$WORK/proj"
export CLAUDE_PLUGIN_ROOT="$ROOT"
SELF="$WORK/proj/.maude/plugin"
EYE="$ROOT/hooks/scripts/maude-eye.sh"
A="aaaaaaaa-1111-2222-3333-444444444444"
B="bbbbbbbb-1111-2222-3333-444444444444"

printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"fix the bug"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x.py"}}]}}' \
  > "$WORK/t.jsonl"
cat > "$WORK/runner-signal" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"signal": true, "kind": "churn", "whisper": "stub caught session A"}\n'
EOF
chmod +x "$WORK/runner-signal"
export MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-signal"

ev() { printf '{"session_id":"%s","transcript_path":"%s","tool_name":"Read"}' "$1" "$WORK/t.jsonl"; }
tick() { ev "$1" | bash "$EYE" tick >/dev/null 2>&1; }
whisper() { printf '{"session_id":"%s","prompt":"x"}' "$1" | bash "$EYE" whisper 2>/dev/null; }

# ── counters ───────────────────────────────────────────────────────────
test_start "each session counts its own ticks"
tick "$A"; tick "$A"; tick "$A"; tick "$B"
assert_eq "$(sed -n 1p "$SELF/eye-state.$A" 2>/dev/null)" "3" "A counted 3"
assert_eq "$(sed -n 1p "$SELF/eye-state.$B" 2>/dev/null)" "1" "B counted 1"
assert_file_absent "$SELF/eye-state" "no shared counter was written"

# ── a whisper reaches its own session and no other ─────────────────────
test_start "the blink A's tick spawns writes A's whisper"
printf '24\n0\n100\n' > "$SELF/eye-state.$A"   # one below the burst; last blink long ago
tick "$A"
for _i in $(seq 1 100); do [ -s "$SELF/eye-whisper.$A.txt" ] && break; sleep 0.1; done
assert_file_exists "$SELF/eye-whisper.$A.txt" "A's whisper landed under A's name"
assert_file_absent "$SELF/eye-whisper.txt" "nothing landed in the shared whisper"

test_start "session B's prompt does not receive A's whisper, and does not eat it"
OUT="$(whisper "$B")"
assert_eq "$OUT" "" "B hears nothing"
[ -s "$SELF/eye-whisper.$A.txt" ] || _fail "B's pickup consumed A's whisper"

test_start "session A's prompt receives it, once"
OUT="$(whisper "$A")"
assert_contains "$OUT" "**Maude:** stub caught session A" "A hears its own eye"
assert_eq "$(whisper "$A")" "" "one-shot: the second prompt hears nothing"

# ── lanes never wait on each other ─────────────────────────────────────
test_start "a held lock in session A does not stall session B's tick"
REL="$WORK/release"
( . "$ROOT/hooks/scripts/_maude-common.sh"
  maude_locked "$SELF/.eye-state.$A.lock" sh -c "touch '$WORK/held'; while [ ! -f '$REL' ]; do sleep 0.1; done" ) &
HOLDER=$!
for _i in $(seq 1 50); do [ -f "$WORK/held" ] && break; sleep 0.1; done
BEFORE="$(sed -n 1p "$SELF/eye-state.$B")"
T0=$SECONDS
ev "$B" | bash "$EYE" tick >/dev/null 2>&1
EL=$((SECONDS - T0))
touch "$REL"; wait "$HOLDER" 2>/dev/null
[ "$EL" -le 1 ] || _fail "B's tick waited ${EL}s on A's lock"
assert_eq "$(sed -n 1p "$SELF/eye-state.$B")" "$((BEFORE + 1))" "B's tick landed"

test_start "a held UNKEYED state lock does not stall a keyed session's tick"
# Kills the mutation that left the tick on the shared .eye-state.lock (the lens, M10).
REL="$WORK/release2"; rm -f "$WORK/held2"
( . "$ROOT/hooks/scripts/_maude-common.sh"
  maude_locked "$SELF/.eye-state.lock" sh -c "touch '$WORK/held2'; while [ ! -f '$REL' ]; do sleep 0.1; done" ) &
HOLDER=$!
for _i in $(seq 1 50); do [ -f "$WORK/held2" ] && break; sleep 0.1; done
BEFORE="$(sed -n 1p "$SELF/eye-state.$B")"
T0=$SECONDS
tick "$B"
EL=$((SECONDS - T0))
touch "$REL"; wait "$HOLDER" 2>/dev/null
[ "$EL" -le 1 ] || _fail "B's tick waited ${EL}s on the shared lock"
assert_eq "$(sed -n 1p "$SELF/eye-state.$B")" "$((BEFORE + 1))" "B's tick landed"

test_start "a whisper's age is its OWN session's: another lane's blink never stales it"
# Kills the mutation that kept eye-whisper.born shared (M12): B's blink rewrote the one
# born stamp with B's small total, and A's whisper read ~500 tool calls old and dropped.
rm -f "$SELF"/eye-whisper.*
printf '24\n0\n500\n' > "$SELF/eye-state.$A"; tick "$A"
for _i in $(seq 1 100); do [ -s "$SELF/eye-whisper.$A.txt" ] && break; sleep 0.1; done
printf '24\n0\n5\n' > "$SELF/eye-state.$B"; tick "$B"
for _i in $(seq 1 100); do [ -s "$SELF/eye-whisper.$B.txt" ] && break; sleep 0.1; done
assert_contains "$(whisper "$A")" "stub caught session A" "A's whisper still fresh after B blinked"

test_start "one session's blink in flight does not block another session's blink"
# Kills the mutation that kept the spawn lock shared (M14): A's slow blink held the one
# .eye-blink.lock, so B's burst spawned nothing.
cat > "$WORK/runner-slow" <<'EOF'
#!/usr/bin/env bash
IN="$(cat)"
case "$IN" in *SLOWMARK*) sleep 6 ;; esac
printf '{"signal": true, "kind": "churn", "whisper": "blink done"}\n'
EOF
chmod +x "$WORK/runner-slow"
printf '{"type":"user","message":{"role":"user","content":"SLOWMARK hold the blink"}}\n' > "$WORK/slow.jsonl"
rm -f "$SELF"/eye-whisper.*
printf '24\n0\n1\n' > "$SELF/eye-state.$A"
printf '{"session_id":"%s","transcript_path":"%s","tool_name":"Read"}' "$A" "$WORK/slow.jsonl" \
  | MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-slow" bash "$EYE" tick >/dev/null 2>&1
sleep 0.5
printf '24\n0\n1\n' > "$SELF/eye-state.$B"
ev "$B" | MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-slow" bash "$EYE" tick >/dev/null 2>&1
for _i in $(seq 1 40); do [ -s "$SELF/eye-whisper.$B.txt" ] && break; sleep 0.1; done
assert_file_exists "$SELF/eye-whisper.$B.txt" "B blinked while A's blink was still running"
for _i in $(seq 1 80); do [ -d "$SELF/.eye-blink.$A.lock" ] || break; sleep 0.1; done

test_start "an overlong session id never becomes a filename (NAME_MAX)"
LONG="$(printf 'a%.0s' $(seq 1 250))"
rm -f "$SELF/eye-state"
tick "$LONG"
assert_file_exists "$SELF/eye-state" "falls back to the unkeyed counter"

test_start "the sweep removes a gone session's eye files, keeps live and legacy ones"
. "$ROOT/hooks/scripts/_maude-common.sh"
printf '1\n0\n1\n' > "$SELF/eye-state.gone"; touch_ago 864000 "$SELF/eye-state.gone"
printf 'x\n' > "$SELF/eye-whisper.gone.txt"; touch_ago 864000 "$SELF/eye-whisper.gone.txt"
touch_ago 864000 "$SELF/eye-state"
maude_retention_sweep
assert_file_absent "$SELF/eye-state.gone" "gone session's counter swept"
assert_file_absent "$SELF/eye-whisper.gone.txt" "gone session's whisper swept"
assert_file_exists "$SELF/eye-state.$B" "a live session's counter kept"
assert_file_exists "$SELF/eye-state" "the legacy unkeyed counter is not the sweep's"

# ── an unsafe id never becomes a path ──────────────────────────────────
test_start "a session id that is not a plain token falls back to the unkeyed files"
# The unkeyed counter is removed FIRST, so its presence after the tick is this tick's
# doing, not an earlier test's leftover (lens 5: the assertion passed by order).
rm -f "$SELF/eye-state"
tick "../../escape"
assert_file_exists "$SELF/eye-state" "unkeyed counter used"
[ -z "$(find "$WORK" -name 'escape*' 2>/dev/null)" ] || _fail "an eye file escaped the store"

print_summary
teardown_test_env
exit $FAILED
