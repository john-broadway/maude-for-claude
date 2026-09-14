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
# The transcript carries a digits-only token so the wait at the end can find our workers by
# it. pgrep -f reads its pattern as a regular expression; a path is not one. The token ends
# in 1, so of the two sleeps the probe below starts, only the decoy's argument ends in 0 and a
# control can slow that one alone; `$$$RANDOM` ended in 0 about one draw in ten (twentieth
# pass's leg), and the control then slowed both.
T_TOKEN="$$${RANDOM}1"
TRANSCRIPT="$WORK/t-$T_TOKEN.jsonl"
EVENT="{\"transcript_path\":\"$TRANSCRIPT\",\"tool_name\":\"Read\"}"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$TRANSCRIPT"

# The wait at the end of this file proves our blink workers exited by asking pgrep -f with
# a $-anchored pattern. With pgrep absent, that loop broke on rc 127 and the count read 0:
# ok over live workers, found by a control after the seventeenth pass. A pgrep that is
# present but sees nothing (a hidepid /proc, a stripped build) passes it the same way. So
# prove the instrument first, on processes this file owns, by the wait's own shape: a
# two-word cmdline, -f, a $-anchor, and exactly one pid back. The decoy differs from the
# probe only past the anchor (the same number of seconds, spelled with a trailing zero), so
# a pgrep that ignores a trailing $ returns two pids and refuses; without it the anchor was
# decoration, and the eighteenth pass dropped it with nothing moving. The children still
# carry bash's cmdline until they exec sleep, so poll: first the decoy must be visible, then
# the anchored pattern is read, and the loop ends only when the probe's own pid is in that
# reading. Order matters: a first version read the pattern first and confirmed the decoy
# after, so a decoy that exec'd between the two calls left a stale one-pid reading and an
# anchor-ignoring pgrep walked through with the decoy slowed 0.5s: 18 of 20 for the
# twentieth pass, 15 of 20 for the author.
# Refuse before the first tick, so a blind instrument spawns nothing into the next file;
# tests/run.sh reads exit 2 as FAIL. The suite's own run of this file is the positive
# control: a probe that fails on a working box would refuse here, and 61/61 could not be
# green.
sleep "7.${T_TOKEN}0" & _DECOY=$!
sleep "7.$T_TOKEN" & _PROBE=$!
_SEEN=""; _DECOY_SEEN=""; _ASKED=""
# The cap below is an ITERATION count, not a time cap: the wall clock is 20 x (0.1s + up to two
# pgrep calls + a bash spawn, because under a shim dir `sleep` is a script). Measured on Debian
# at 2.42s mean over 10 runs, NOT the ~2.1s an earlier draft of this comment computed; on the
# GitHub macOS runner inside install-smoke's nested fleet it is enough longer that a control
# slowing the probe by 4s was outrun and the red said only "expected exit=2 got=0" (2026-09-13).
#
# The margin is reported on BOTH paths, which the first version of this instrument got wrong:
# it printed only inside the refusal below, and on the observed red `_SEEN` equals `_PROBE`, so
# that block is skipped and the line was never produced at all. On a green run it was produced
# and discarded. An instrument that cannot observe either state it was built for is not an
# instrument. The success path therefore prints a NOTE, which tests/run.sh passes through on a
# PASS, so a green macOS run finally reports this platform's real poll duration.
#
# $SECONDS is integer, so the number is a FLOOR (measured over 30 local runs it read 2s
# sixteen times and 3s fourteen, purely from where the process starts against a second
# boundary; an earlier draft said 8 of 10, which the 2.42s mean three lines up already refuted). The pass count is the exact
# half of the reading: 20 of 20 means the poll exhausted.
_POLL_START=$SECONDS; _PASSES=0
for _w in {1..20}; do
  _PASSES=$_w
  if _DECOY_SEEN="$(pgrep -f "^sleep 7\.${T_TOKEN}0$" 2>&1)"; then
    _ASKED=1; _SEEN="$(pgrep -f "^sleep 7\.${T_TOKEN}$" 2>&1)"
    printf '%s\n' "$_SEEN" | grep -qx "$_PROBE" && break
  fi
  sleep 0.1
done
_POLL_ELAPSED=$((SECONDS - _POLL_START))
# ONE canonical reading, emitted byte-identically on both paths. Two wordings is what made the
# previous surfacing blind: the reader grepped the refusal's phrasing, and on the OBSERVED red
# the probe IS seen, so the success phrasing landed instead, the grep matched nothing, and an
# unconditional printf emitted an empty NOTE that still satisfied run.sh's `NOTE ` filter. A
# reading that can be absent while still looking produced is worse than no reading.
_POLL_READING="eye-poll ${_POLL_ELAPSED}s(floor) ${_PASSES}/20 passes"
kill "$_DECOY" "$_PROBE" 2>/dev/null; wait "$_DECOY" "$_PROBE" 2>/dev/null
if [ "$_SEEN" = "$_PROBE" ]; then
  printf '  NOTE  %s\n' "$_POLL_READING"
fi
if [ "$_SEEN" != "$_PROBE" ]; then
  # Say what was seen, then every cause that reading leaves open, never one diagnosis: the
  # twenty-second pass read the one-cause wording clear the instrument for a pgrep that failed
  # the probe's pattern alone, and call a probe that was never asked for "not visible". Whether
  # the probe's pattern was read at all is a fact the poll records, not one inferred from an
  # empty capture (the initialiser is empty too).
  if [ -z "$_ASKED" ]; then
    _WHY="the decoy check never succeeded, so the probe's pattern was never read: a blind or absent pgrep, a stalled box, or a decoy that died first"
  elif [ -z "$_SEEN" ]; then
    _WHY="the decoy was seen and the probe was not: a probe late to exec, a probe that died first, or a pgrep that fails the probe's pattern alone"
  else
    case "$(printf '%s' "$_SEEN" | tr -d '\n')" in
      *[!0-9]*) _WHY="pgrep printed something that is not a pid list: a wrapper or a build that writes more than pids" ;;
      *)        _WHY="pgrep returned pids other than exactly the probe's: a match past the anchor, or a different process" ;;
    esac
  fi
  printf 'tests/test-eye-hooks.sh: pgrep -f "^sleep 7\\.%s$" returned "%s" (the decoy check returned "%s") for probe pid %s [%s]; %s; so this file does not run\n' "$T_TOKEN" "$_SEEN" "$_DECOY_SEEN" "$_PROBE" "$_POLL_READING" "$_WHY" >&2
  exit 2
fi

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

# 6) wall-clock staleness is OPT-IN (MAUDE_EYE_WHISPER_TTL, default off): set, a whisper past it never wears a fresh voice (issue #35)
test_start "stale whisper is dropped, not printed"
printf 'watch the thing that already resolved\n' > "$SELF/eye-whisper.txt"
touch_ago $(( 10*60 )) "$SELF/eye-whisper.txt"
OUT3="$(MAUDE_EYE_WHISPER_TTL=300 bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_eq "$OUT3" "" "stale whisper is dropped"

test_start "stale drop clears the file (no zombie on next pickup)"
assert_eq "$(cat "$SELF/eye-whisper.txt" 2>/dev/null)" "" "stale whisper cleared"

test_start "stale drop leaves a trace receipt"
assert_contains "$(cat "$SELF/trace/"today-*.jsonl 2>/dev/null)" "stale whisper dropped" "drop is auditable"

test_start "TTL is configurable (MAUDE_EYE_WHISPER_TTL)"
printf 'still warm under a long TTL\n' > "$SELF/eye-whisper.txt"
touch_ago $(( 10*60 )) "$SELF/eye-whisper.txt"
OUT4="$(MAUDE_EYE_WHISPER_TTL=1200 bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_contains "$OUT4" "still warm under a long TTL" "long TTL keeps it fresh"

# 7) freshness is measured in tool calls since the whisper was born, not in seconds.
# Pickup happens only at the next human prompt; a wall-clock TTL shorter than the
# human's turn cadence dropped every whisper (0 of 10 delivered over three days,
# 2026-09-14) while the work had not moved at all.
test_start "tick keeps a monotonic total on line 3 of eye-state"
rm -f "$STATE"
for _i in 1 2 3 4; do printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1; done
assert_eq "$(sed -n 3p "$STATE")" "4" "total counts every tick"

test_start "blink spawn resets the burst count but not the total"
printf '25\n0\n30\n' > "$STATE"
printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1
assert_eq "$(sed -n 1p "$STATE")" "0" "burst reset"
assert_eq "$(sed -n 3p "$STATE")" "31" "total kept"

test_start "blink spawn records the birth tick of the whisper it may produce"
assert_eq "$(cat "$SELF/eye-whisper.born" 2>/dev/null)" "31" "birth tick recorded at spawn"

test_start "a 10-minute-old whisper with no work since is FRESH (wall clock is not the measure)"
printf 'nothing moved, still true\n' > "$SELF/eye-whisper.txt"
touch_ago $(( 10*60 )) "$SELF/eye-whisper.txt"
printf '31' > "$SELF/eye-whisper.born"; printf '3\n0\n34\n' > "$STATE"
OUT5="$(bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_contains "$OUT5" "**Maude:** nothing moved, still true" "fresh by tool calls"

test_start "a whisper more than MAUDE_EYE_WHISPER_TTL_ACTIONS tool calls old is dropped"
printf 'the work moved on\n' > "$SELF/eye-whisper.txt"
printf '31' > "$SELF/eye-whisper.born"; printf '10\n0\n72\n' > "$STATE"
OUT6="$(bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_eq "$OUT6" "" "41 calls > default 40 → dropped"
assert_contains "$(cat "$SELF/trace/"today-*.jsonl 2>/dev/null)" "aged 41 tool calls" "receipt names the measure"

test_start "MAUDE_EYE_WHISPER_TTL_ACTIONS is configurable"
printf 'the work moved on\n' > "$SELF/eye-whisper.txt"
printf '31' > "$SELF/eye-whisper.born"; printf '10\n0\n72\n' > "$STATE"
OUT7="$(MAUDE_EYE_WHISPER_TTL_ACTIONS=100 bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_contains "$OUT7" "the work moved on" "wider budget keeps it"

test_start "60 parallel ticks all land in the total (the state file is read-modify-write under a lock)"
# The lens (2026-09-14) ran 60 concurrent ticks against the unlocked file and read 5.
rm -f "$STATE"; rmdir "$LOCK" 2>/dev/null
printf '0\n%s\n0\n' "$(date +%s)" > "$STATE"   # blinked just now: the interval keeps every racer from spawning
for _i in $(seq 1 60); do (printf '%s' "$EVENT" | bash "$ROOT/hooks/scripts/maude-eye.sh" tick >/dev/null 2>&1) & done
wait
assert_eq "$(sed -n 3p "$STATE")" "60" "no tick lost"
assert_eq "$(sed -n 1p "$STATE")" "60" "burst count kept too"

test_start "a whisper with no birth record is treated as fresh (fail-open, as before)"
printf 'born before the counter existed\n' > "$SELF/eye-whisper.txt"
rm -f "$SELF/eye-whisper.born"; printf '10\n0\n500\n' > "$STATE"
OUT8="$(bash "$ROOT/hooks/scripts/maude-eye.sh" whisper 2>/dev/null)"
assert_contains "$OUT8" "born before the counter existed" "no birth → fresh"

# Every blink this file spawns is nohup'd and disowned (hooks/scripts/maude-eye.sh:51). One
# still starting when this file exits rebuilds the swept closet with its first mkdir -p
# (maude-eye-blink.sh:12), and tests/run.sh charges that to whichever file finishes next.
# Measured 2026-09-05 with the blink's startup delayed 25s: the closet came back under the
# swept root 35s after this file had exited. Wait for our own workers by the token in the
# transcript's name, never by its path: the first version interpolated $WORK into the
# pattern, and one parenthesis in an ancestor of TMPDIR made pgrep match nothing and this
# line say ok over four live workers (seventeenth pass). A cap, so a hung worker is a red
# line and not a hung suite.
test_start "no blink outlives this file"
for _w in {1..200}; do
  pgrep -f "maude-eye-blink\.sh .*t-${T_TOKEN}\.jsonl$" >/dev/null 2>&1 || break
  sleep 0.3
done
assert_eq "$(pgrep -f "maude-eye-blink\.sh .*t-${T_TOKEN}\.jsonl$" | wc -l | tr -d ' ')" "0" "every blink this file spawned has exited"

teardown_test_env
print_summary; exit $FAILED
