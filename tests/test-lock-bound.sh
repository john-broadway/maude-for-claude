#!/usr/bin/env bash
# maude_locked waits a BOUNDED time, and every caller fails in its safe direction.
#
# Earned 2026-09-25: the wait was unbounded, so the only bound was the harness's 5 s hook
# timer. Five sessions on one box share one .maude/plugin store; a holder past the budget
# turned every waiter into a "hook timed out" on the person's screen (reproduced: an eye
# tick behind a held lock died at 5003 ms, rc 124). A lost tick is cheap; a timer error
# on every prompt is not. On timeout the command does NOT run and maude_locked returns 75.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$HOOKS_DIR/_maude-common.sh"

SELF="$TEST_TMP/.maude/plugin"
mkdir -p "$SELF"
L="$SELF/probe.lock"
RAN="$TEST_TMP/ran"

# Hold a lock through maude_locked itself, so the holder is whatever this box uses (flock
# here, the mkdir fallback on macOS), until release(). Killing the holder is NOT a release:
# its child keeps the lock's fd open (measured: the next waiter sat 2.7 s), so the next
# test's holder would time out against this one.
hold() {  # <lock>
  local up="$TEST_TMP/held.$RANDOM"
  REL="$TEST_TMP/release.$RANDOM"
  ( maude_locked "$1" sh -c "touch '$up'; while [ ! -f '$REL' ]; do sleep 0.1; done" ) &
  HOLDER=$!
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$up" ] && return 0; sleep 0.1
  done
  return 1
}
release() { touch "$REL"; wait "$HOLDER" 2>/dev/null; }
# Every waiter runs in its own process under an outer 10 s bound, so an UNBOUNDED lock
# reads as a failure (124), never as a suite that hangs (the first red of this file hung).
waiter() { maude_timeout 10 bash -c '. "$1/_maude-common.sh"; shift; "$@"' _ "$HOOKS_DIR" "$@"; }

# ── control: a free lock runs the command ──────────────────────────────
test_start "free lock: the command runs, rc is its own"
rm -f "$RAN"
maude_locked "$L" touch "$RAN"
assert_exit "$?" "0" "free lock rc"
assert_file_exists "$RAN" "command ran under a free lock"

# ── the bound ──────────────────────────────────────────────────────────
test_start "held lock: the waiter gives up inside its bound, rc 75, command NOT run"
rm -f "$RAN"
hold "$L" || _fail "holder never took the lock"
T0=$SECONDS
MAUDE_LOCK_WAIT=1 waiter maude_locked "$L" touch "$RAN"
RC=$?
EL=$((SECONDS - T0))
assert_exit "$RC" "75" "timed-out wait returns 75"
assert_file_absent "$RAN" "command did not run without the lock"
[ "$EL" -le 3 ] || _fail "waited ${EL}s against a 1 s bound"
release

test_start "a non-numeric MAUDE_LOCK_WAIT falls back to the default, never waits forever"
hold "$L" || _fail "holder never took the lock"
T0=$SECONDS
# lens 5 (mutation survivor): the 60 s cap on a THREE-digit wait had no test that could
# see it go (only 4+ digits hit the length guard). The parse is a function; read it.
test_start "the wait parses base 10 and caps at 60 without waiting it out"
assert_eq "$(waiter maude_lock_wait 999)" "60" "999 → 60"
assert_eq "$(waiter maude_lock_wait 61)" "60" "61 → 60"
assert_eq "$(waiter maude_lock_wait 60)" "60" "60 → 60"
assert_eq "$(waiter maude_lock_wait 08)" "8" "08 → 8, base 10"
assert_eq "$(waiter maude_lock_wait abc)" "2" "abc → the default"
assert_eq "$(waiter maude_lock_wait '')" "2" "empty → the default"
assert_eq "$(waiter maude_lock_wait 99999999999999999999)" "60" "20 digits → 60, never an overflow"
assert_eq "$(MAUDE_LOCK_WAIT=7 waiter maude_lock_wait)" "7" "reads MAUDE_LOCK_WAIT when unargued"

MAUDE_LOCK_WAIT=forever waiter maude_locked "$L" true
RC=$?
EL=$((SECONDS - T0))
assert_exit "$RC" "75" "garbage bound still times out"
[ "$EL" -le 4 ] || _fail "waited ${EL}s on a garbage bound (default is 2)"
release

# ── the fallback path (no flock: macOS) is bounded the same way ────────
test_start "no-flock fallback: a LIVE holder's dir times the waiter out at its bound, rc 75"
NOFLOCK="$(make_no_binary_bin flock)"
mkdir -p "$L.d"
rm -f "$RAN"
T0=$SECONDS
PATH="$NOFLOCK" maude_timeout 10 bash -c ". '$HOOKS_DIR/_maude-common.sh'; MAUDE_LOCK_WAIT=1 maude_locked '$L' touch '$RAN'"
RC=$?
EL=$((SECONDS - T0))
rmdir "$L.d" 2>/dev/null
assert_exit "$RC" "75" "fallback timed out"
assert_file_absent "$RAN" "fallback did not run the command"
[ "$EL" -le 3 ] || _fail "fallback waited ${EL}s against a 1 s bound"

test_start "no-flock fallback: a leading-zero or garbage bound still times out as busy (base 10, digit guard)"
mkdir -p "$L.d"
# "08" is a real 8 s bound (base 10), so it is judged on its rc: before the fix it was a
# bash arithmetic error, rc 1. Its outer bound leaves room for the fallback's per-spin
# overhead under load (the full suite measured 10 s against a 9 s ceiling).
# "forever" falls back to the default 2 s.
for W in 08 forever; do
  case "$W" in 08) CEIL=15; FLOOR=6 ;; *) CEIL=6; FLOOR=0 ;; esac
  T0=$SECONDS
  PATH="$NOFLOCK" maude_timeout 20 bash -c ". '$HOOKS_DIR/_maude-common.sh'; MAUDE_LOCK_WAIT=$W maude_locked '$L' true"
  RC=$?
  EL=$((SECONDS - T0))
  assert_exit "$RC" "75" "MAUDE_LOCK_WAIT=$W reads busy, not an arithmetic error"
  [ "$EL" -le "$CEIL" ] || _fail "MAUDE_LOCK_WAIT=$W waited ${EL}s (ceiling $CEIL)"
  # A floor, or a mutant reading "08" as a 0 s wait passes on rc alone (lens 3).
  [ "$EL" -ge "$FLOOR" ] || _fail "MAUDE_LOCK_WAIT=$W waited only ${EL}s (floor $FLOOR): not read as 8"
done
rmdir "$L.d" 2>/dev/null

test_start "no-flock fallback: a STALE dir (dead holder) is still reclaimed"
mkdir -p "$L.d"; touch_ago 120 "$L.d"
rm -f "$RAN"
PATH="$NOFLOCK" maude_timeout 10 bash -c ". '$HOOKS_DIR/_maude-common.sh'; MAUDE_LOCK_WAIT=1 maude_locked '$L' touch '$RAN'"
assert_exit "$?" "0" "stale dir reclaimed"
assert_file_exists "$RAN" "command ran after the reclaim"

# ── every caller fails in its safe direction ──────────────────────────
CARE="$SELF/care.json"
NOW=$(date +%s)
# Reserved by the call that will run (fp1), the way the gate leaves it at PreToolUse: a
# queued spend names that reservation (lens 2, I1).
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sid1","at":%d,"fp":"fp1","head":"git push","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
BEFORE="$(cat "$CARE")"

test_start "care_set behind a held lock: nonzero, file untouched"
hold "$CARE.lock" || _fail "holder never took the lock"
MAUDE_LOCK_WAIT=1 waiter maude_care_set "$CARE" '.x = 1'
assert_ne "$?" "0" "care_set reports the write did not land"
assert_eq "$(cat "$CARE")" "$BEFORE" "care.json unchanged"

test_start "reserve behind a held lock says busy (never 'none': the person HOLDS a clear)"
OUT="$(MAUDE_LOCK_WAIT=1 waiter maude_care_reserve_token "$CARE" git-push sid1 "$NOW" fp1 'git push')"
assert_eq "$OUT" "busy" "reserve under contention"

test_start "take_token behind a held lock says busy (nothing read; the caller blocks)"
OUT="$(MAUDE_LOCK_WAIT=1 waiter maude_care_take_token "$CARE" git-push "$NOW")"
assert_eq "$OUT" "busy" "take under contention"
assert_eq "$(cat "$CARE")" "$BEFORE" "token not consumed"

test_start "consume behind a held lock QUEUES the spend (the command ran; never 'none')"
OUT="$(MAUDE_LOCK_WAIT=1 waiter maude_care_consume_token "$CARE" git-push fp1 'git push')"
assert_eq "$OUT" "queued" "consume under contention"
assert_file_exists "$CARE.spent-git-push" "a spent marker is left beside the store"
release

test_start "the queued spend lands on the next locked read: the token cannot pass again"
OUT="$(waiter maude_care_reserve_token "$CARE" git-push sid1 "$NOW" fp1 'git push')"
assert_eq "$OUT" "none" "the drained token is gone"
assert_eq "$(jq -r '.gate_cleared["git-push"] // "absent"' "$CARE")" "absent" "spent in the store"
assert_file_absent "$CARE.spent-git-push" "the marker is drained"

# lens 5 (BLOCKING): `mv -f marker DIR` moves the marker INTO the directory and succeeds,
# the drain's -f test never sees a marker, and the same bytes pass again on a token the
# person believed spent. The obstacle is moved aside (never deleted) and the mark lands.
test_start "a DIRECTORY at the marker path cannot swallow a queued spend: the token still cannot pass twice"
NOW=$(date +%s)
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sid1","at":%d,"fp":"fp1","head":"git push","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
rm -rf "$CARE.spent-git-push"; mkdir -p "$CARE.spent-git-push"
hold "$CARE.lock" || _fail "could not take the lock"
OUT="$(MAUDE_LOCK_WAIT=1 waiter maude_care_consume_token "$CARE" git-push fp1 'git push' sid1)"
assert_eq "$OUT" "queued" "the busy consume is queued"
[ -f "$CARE.spent-git-push" ] && [ ! -d "$CARE.spent-git-push" ] && _pass || _fail "the marker is not a regular file at its path"
release
OUT="$(MAUDE_TOKEN_RETRY_MIN=0 waiter maude_care_reserve_token "$CARE" git-push sid1 "$NOW" fp1 'git push')"
assert_eq "$OUT" "none" "the same bytes do not pass a second time"
assert_file_absent "$CARE.spent-git-push" "the marker is drained"
rm -rf "$CARE".spent-git-push.notafile.* 2>/dev/null
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"

# lens 5 (mutation survivor): every fixture that varied the session also varied the fp,
# so "the marker's fp must MATCH" was indistinguishable from "the marker has an fp".
test_start "a marker from the SAME session but ANOTHER fp spends nothing (the fp must match, not merely exist)"
NOW=$(date +%s)
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sid1","at":%d,"fp":"fpA","head":"git push a","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 'sid1\037fpB\037git push b\n' > "$CARE.spent-git-push"
OUT="$(MAUDE_TOKEN_RETRY_MIN=0 waiter maude_care_reserve_token "$CARE" git-push sid1 "$NOW" fpA 'git push a')"
assert_eq "$OUT" "live" "the reservation for fpA stands; fpB's marker did not spend it"
assert_file_absent "$CARE.spent-git-push" "the stale marker is dropped"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"

test_start "a marker for ANOTHER call's reservation spends nothing and is dropped"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s2","at":%d,"fp":"OTHER","head":"x","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 'sid1\037fp1\037git push\n' > "$CARE.spent-git-push"
waiter maude_care_take_token "$CARE" nothing-key "$NOW" >/dev/null
OUT="$(waiter maude_care_reserve_token "$CARE" git-push s2 "$NOW" OTHER 'x')"
assert_eq "$OUT" "inflight" "the other call's reservation is untouched"
assert_file_absent "$CARE.spent-git-push" "the stale marker is dropped"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"

# ── the drain spends only the reservation its marker names (lens 2, I1) ──
# A queued marker must never eat a LATER, unrelated clear: John re-clears (an unreserved
# token) and the old marker deleted it, so the gate sent him for a clear he had just given.
NOW=$(date +%s)
test_start "a stale marker does not eat a fresh clear (the old token expired first)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"
printf 'sidF\037F\037git push old\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_reserve_token "$CARE" git-push sidG "$NOW" G 'git push new')"
assert_eq "$OUT" "live" "the fresh clear reserves for the new call"
assert_file_absent "$CARE.spent-git-push" "the stale marker is dropped"

test_start "a stale marker does not eat a fresh clear through take_token (the RED infra path)"
printf '{"gate_cleared":{"infra-destructive":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"
printf 'sidF\037F\037x\n' > "$CARE.spent-infra-destructive"
OUT="$(waiter maude_care_take_token "$CARE" infra-destructive "$NOW")"
assert_eq "$OUT" "live" "the fresh RED clear passes once"

test_start "an empty-fp marker names no call and spends nothing"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"
printf 'sidG\037\037\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_reserve_token "$CARE" git-push sidG "$NOW" G 'git push new')"
assert_eq "$OUT" "live" "fresh clear kept"
assert_file_absent "$CARE.spent-git-push" "the nameless marker is dropped"

test_start "take_token drains first: a queued spend lands before the token is read"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 's\037F\037h\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_take_token "$CARE" git-push "$NOW")"
assert_eq "$OUT" "none" "the queued spend landed; nothing left to take"

test_start "consume drains first: a queued spend lands even when this consume is another call's"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 's\037F\037h\n' > "$CARE.spent-git-push"
waiter maude_care_consume_token "$CARE" git-push OTHER 'x' >/dev/null
assert_eq "$(jq -r '.gate_cleared["git-push"] // "absent"' "$CARE")" "absent" "the queued spend landed"
rm -f "$CARE.spent-git-push"

# ── lens 3, I-A: nothing spends a token its call does not hold ─────────
NOW=$(date +%s)
# NOT tested, on purpose: lens 3's I-A (a re-clear given while a command runs survives that
# command's consume). The 25th lens's MINOR-6 wins: an unreserved live token is spent by the
# command that ran (tests/test-trace.sh), because the gate that should have reserved it may
# never have run, and a one-shot left open passes a second command. Named residual.
test_start "I-A: a consume from another session spends nothing"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sB","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
OUT="$(waiter maude_care_consume_token "$CARE" git-push F h sA)"
assert_eq "$OUT" "none" "same bytes, other lane"
assert_eq "$(jq -r '.gate_cleared["git-push"].reserved.sid' "$CARE")" "sB" "B keeps its reservation"

test_start "I-A: a late marker from another session never eats this session's reservation"
printf 'sA\037F\037h\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_reserve_token "$CARE" git-push sB "$NOW" F h)"
assert_eq "$OUT" "inflight" "B's reservation stands"
assert_file_absent "$CARE.spent-git-push" "A's marker is dropped as stale"

# ── lens 4: the session plumbing, end to end and through the writer ───
test_start "lens 4 I-1: a marker from an envelope with no session id ('default') still spends"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"abcd1234","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 'default\037F\037h\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_reserve_token "$CARE" git-push abcd1234 "$NOW" F h)"
assert_eq "$OUT" "none" "drained: the same bytes do not pass again"

test_start "lens 4 M5: the busy consume writes the session into its marker"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sX","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
hold "$CARE.lock" || _fail "holder never took the lock"
MAUDE_LOCK_WAIT=1 waiter maude_care_consume_token "$CARE" git-push F h sX >/dev/null
release
assert_eq "$(cut -d"$(printf '\037')" -f1 "$CARE.spent-git-push")" "sX" "the marker names its session"
rm -f "$CARE.spent-git-push"

test_start "lens 4 M6: through the gate, another session's same bytes do not spend a reservation"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $((NOW + 600)) > "$CARE"
make_bash_tool_input "git push origin main" | jq -c '. + {session_id:"aaaa1111-x"}' \
  | bash "$HOOKS_DIR/maude-gate.sh" >/dev/null 2>&1
make_bash_tool_input "git push origin main" | jq -c '. + {session_id:"bbbb2222-x"}' \
  | bash "$HOOKS_DIR/maude-gate.sh" consume >/dev/null 2>&1
# The WHOLE id is the session (lens 5): the gate cut it to 8 characters, and this line
# asserted the cut.
assert_eq "$(jq -r '.gate_cleared["git-push"].reserved.sid // "absent"' "$CARE")" "aaaa1111-x" "A's reservation stands, under its whole id"
make_bash_tool_input "git push origin main" | jq -c '. + {session_id:"aaaa1111-x"}' \
  | bash "$HOOKS_DIR/maude-gate.sh" consume >/dev/null 2>&1
assert_eq "$(jq -r '.gate_cleared["git-push"] // "absent"' "$CARE")" "absent" "A's own consume spends it"

test_start "lens 4 M3: an old-shape reservation (no v) names no call, whatever session consumes"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"sB","at":%d}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
OUT="$(waiter maude_care_consume_token "$CARE" git-push F h sA)"
assert_eq "$OUT" "spent" "spent by the command that ran"

# ── lens 3, I-C: every drain branch can fail its test ─────────────────
test_start "I-C: a marker naming its call by HEAD (nothing could hash) spends that call's token"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s","at":%d,"fp":"","head":"git push x","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 's\037\037git push x\n' > "$CARE.spent-git-push"
OUT="$(waiter maude_care_take_token "$CARE" git-push "$NOW")"
assert_eq "$OUT" "none" "spent by head"

test_start "I-C: a marker with neither fp nor head names no call, even against an empty reservation"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s","at":%d,"fp":"","head":"","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 's\037\037\n' > "$CARE.spent-git-push"
waiter maude_care_reserve_token "$CARE" git-push s "$NOW" "" "" >/dev/null
assert_ne "$(jq -r '.gate_cleared["git-push"].until // "absent"' "$CARE")" "absent" "not spent"
assert_file_absent "$CARE.spent-git-push" "and dropped"

test_start "I-C: a junk reservation is not an object: the marker is stale, the token untouched"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":"junk"}}}\n' $((NOW + 600)) > "$CARE"
printf 's\037F\037h\n' > "$CARE.spent-git-push"
waiter maude_care_consume_token "$CARE" git-push ZZ zz s >/dev/null
assert_file_absent "$CARE.spent-git-push" "stale marker dropped"

test_start "I-C: an unreadable store keeps the marker for the next read"
printf 'not json' > "$CARE"
printf 's\037F\037h\n' > "$CARE.spent-git-push"
waiter maude_care_reserve_token "$CARE" git-push s "$NOW" F h >/dev/null
assert_file_exists "$CARE.spent-git-push" "kept"

test_start "I-C: a spend whose write fails keeps the marker (the one-shot must not stay spendable)"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"s","at":%d,"fp":"F","head":"h","v":3}}}}\n' $((NOW + 600)) "$NOW" > "$CARE"
printf 's\037F\037h\n' > "$CARE.spent-git-push"
FAILMV="$TEST_TMP/failmv"; mkdir -p "$FAILMV"
printf '#!/bin/sh\nexit 1\n' > "$FAILMV/mv"; chmod +x "$FAILMV/mv"
PATH="$FAILMV:$PATH" waiter maude_care_reserve_token "$CARE" git-push s "$NOW" F h >/dev/null
assert_file_exists "$CARE.spent-git-push" "kept while the spend cannot land"
rm -f "$CARE.spent-git-push"

test_start "B2 end to end: a busy PostToolUse consume never lets the same command ride again"
# The lens's repro, 2026-09-25: reserve, a held lock across the consume, then the same
# command again after the retry window passed on the one-shot token a second time.
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$CARE"
make_bash_tool_input "git push origin main" | MAUDE_TOKEN_RETRY_MIN=0 bash "$HOOKS_DIR/maude-gate.sh" >/dev/null 2>&1
assert_exit "$?" "0" "the first run passes on its token"
hold "$CARE.lock" || _fail "holder never took the lock"
ERR="$(make_bash_tool_input "git push origin main" | MAUDE_LOCK_WAIT=1 maude_timeout 10 bash "$HOOKS_DIR/maude-gate.sh" consume 2>&1 >/dev/null)"
assert_contains "$ERR" "spend is queued" "the busy consume says so"
release
ERR="$(make_bash_tool_input "git push origin main" | MAUDE_TOKEN_RETRY_MIN=0 bash "$HOOKS_DIR/maude-gate.sh" 2>&1 >/dev/null)"
assert_exit "$?" "2" "the same command does NOT ride the token again"

test_start "B1 end to end: a busy store never leaves a RED infra token live for a second call"
RED="$SELF/care-redclear.json"
printf '{"gate_cleared":{"infra-destructive":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$RED"
hold "$RED.lock" || _fail "holder never took the lock"
ERR="$(make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' | MAUDE_LOCK_WAIT=1 maude_timeout 10 bash "$HOOKS_DIR/maude-infra-gate.sh" 2>&1 >/dev/null)"
assert_exit "$?" "2" "busy blocks; it never passes on an unspent token"
assert_contains "$ERR" "Retry the same call" "and says why"
release
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' | bash "$HOOKS_DIR/maude-infra-gate.sh" >/dev/null 2>&1
assert_exit "$?" "0" "the retry passes, spending the token"
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' | bash "$HOOKS_DIR/maude-infra-gate.sh" >/dev/null 2>&1
assert_exit "$?" "2" "and a second call is refused: one token, one call"

test_start "the bound is per HOOK: after one busy, later waits in the same process do not wait"
hold "$L" || _fail "holder never took the lock"
T0=$SECONDS
MAUDE_LOCK_WAIT=2 maude_timeout 20 bash -c '. "$1/_maude-common.sh"; maude_locked "$2" true; maude_locked "$2" true; maude_locked "$2" true' _ "$HOOKS_DIR" "$L"
RC=$?
EL=$((SECONDS - T0))
release
assert_exit "$RC" "75" "still busy"
[ "$EL" -le 5 ] || _fail "three locks took ${EL}s (a per-call bound is 6; per-hook is ~2)"

test_start "the gate, handed busy, blocks with exit 2 and says RETRY, not 'no token'"
hold "$CARE.lock" || _fail "holder never took the lock"
ERR="$(make_bash_tool_input "git push origin main" | MAUDE_LOCK_WAIT=1 maude_timeout 10 bash "$HOOKS_DIR/maude-gate.sh" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "2" "gate blocks while the token store is busy"
assert_contains "$ERR" "busy" "names the cause"
assert_contains "$ERR" "Retry the same command" "tells the reader what to do"
release

test_start "the eye tick behind a held state lock exits 0 inside the hook budget"
hold "$SELF/.eye-state.lock" || _fail "holder never took the lock"
T0=$SECONDS
printf '{"transcript_path":"/dev/null","tool_name":"Read"}' | MAUDE_LOCK_WAIT=1 maude_timeout 10 bash "$HOOKS_DIR/maude-eye.sh" tick >/dev/null 2>&1
RC=$?
EL=$((SECONDS - T0))
assert_exit "$RC" "0" "tick exits clean"
[ "$EL" -le 3 ] || _fail "tick took ${EL}s behind a held lock"
release

print_summary
teardown_test_env
exit $FAILED
