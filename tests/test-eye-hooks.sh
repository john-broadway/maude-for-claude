#!/usr/bin/env bash
# Eye tick counter/interval + one-shot whisper pickup.
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
STATE="$SELF/eye-state"
LOCK="$SELF/.eye-blink.lock"
EVENT="{\"transcript_path\":\"$WORK/t.jsonl\",\"tool_name\":\"Read\"}"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$WORK/t.jsonl"

# stub runner so a spawned blink can't reach a real model
cat > "$WORK/runner" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; printf '{"signal": false}\n'
EOF
chmod +x "$WORK/runner"
export MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner"

# 1) below threshold: count rises, no reset
test_start "count reaches 3"
for _i in 1 2 3; do printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1; done
assert_contains "$(head -1 "$STATE")" "3" "count reaches 3"

# 2) threshold + interval met -> state resets (blink spawned)
test_start "count reset after blink spawn"
printf '25\n0\n' > "$STATE"     # 25 events, last blink at epoch 0 (long ago)
printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1
assert_contains "$(head -1 "$STATE")" "0" "count reset after blink spawn"

# 2b) race: 8 concurrent ticks that all read the same pre-reset counter must
# spawn exactly one blink, not 8. Before the mkdir-lock claim, each racer
# independently judged the threshold met and spawned its own worker.
test_start "concurrent ticks spawn exactly one blink"
rm -f "$STATE"; rmdir "$LOCK" 2>/dev/null
SPAWNLOG="$WORK/spawn-log"
rm -f "$SPAWNLOG"
cat > "$WORK/runner-logging" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo "\$\$" >> "$SPAWNLOG"
printf '{"signal": false}\n'
EOF
chmod +x "$WORK/runner-logging"
printf '24\n0\n' > "$STATE"    # one tick below threshold — every racer computes 25
for _i in 1 2 3 4 5 6 7 8; do
  ( printf '%s' "$EVENT" | MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-logging" \
      bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1 ) &
done
wait
# The winning tick's blink worker is nohup'd + disowned (so it outlives the
# `wait` above) — poll briefly for it to finish and write its log line.
for _w in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$SPAWNLOG" ] && break
  sleep 0.3
done
SPAWNS="$(wc -l < "$SPAWNLOG" 2>/dev/null | tr -d ' ')"
assert_eq "${SPAWNS:-0}" "1" "concurrent ticks spawn exactly one blink"
# Let the winner's own EXIT trap release the lock before the next scenario.
for _w in 1 2 3 4 5 6 7 8 9 10; do
  [ -d "$LOCK" ] || break
  sleep 0.3
done
rmdir "$LOCK" 2>/dev/null

# 3) threshold met but interval NOT met -> no reset
test_start "interval throttles the blink"
NOW="$(date +%s)"
printf '25\n%s\n' "$NOW" > "$STATE"
printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1
assert_contains "$(head -1 "$STATE")" "26" "interval throttles the blink"

# 4) MAUDE_EYE=off -> inert
test_start "off switch respected"
printf '0\n0\n' > "$STATE"
printf '%s' "$EVENT" | MAUDE_EYE=off bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1
assert_contains "$(head -1 "$STATE")" "0" "off switch respected"

# 5) whisper pickup is one-shot
test_start "whisper surfaces once"
printf 'the hand on the arm\n' > "$SELF/eye-whisper.txt"
OUT1="$(bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_contains "$OUT1" "**Maude:** the hand on the arm" "whisper surfaces once"

test_start "second pickup is silent"
OUT2="$(bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_eq "$OUT2" "" "second pickup is silent"

teardown_test_env
print_summary; exit $FAILED
