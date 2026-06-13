#!/usr/bin/env bash
# Tests for hooks/scripts/maude-clear-gate.sh — writes a one-shot gate token.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

CLEAR="$HOOKS_DIR/maude-clear-gate.sh"

test_start "clear-gate without key prints usage"
ERR="$(bash "$CLEAR" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "1" "no-arg exit"

test_start "clear-gate usage includes known keys"
assert_contains "$ERR" "git-push" "usage mentions key"

test_start "clear-gate writes token for git-push"
bash "$CLEAR" git-push >/dev/null 2>&1
until_val="$(read_care '.gate_cleared["git-push"].until')"
assert_ne "$until_val" "null" "token written"

test_start "default duration is 5 min ahead"
NOW=$(date +%s)
DIFF=$(( until_val - NOW ))
[ "$DIFF" -ge 295 ] && [ "$DIFF" -le 305 ]
assert_exit "$?" "0" "default 300s"

test_start "custom duration honored"
bash "$CLEAR" git-push 1800 >/dev/null 2>&1
until_val="$(read_care '.gate_cleared["git-push"].until')"
NOW=$(date +%s)
DIFF=$(( until_val - NOW ))
[ "$DIFF" -ge 1795 ] && [ "$DIFF" -le 1805 ]
assert_exit "$?" "0" "custom 1800s"

test_start "clear-gate logs trace event"
n="$(count_trace_lines '.kind == "gate-cleared"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

test_start "clear-gate writes friendly message to stdout"
OUT="$(bash "$CLEAR" reset-hard 2>/dev/null)"
assert_contains "$OUT" "Maude: gate cleared" "friendly msg"

test_start "different keys coexist in care.json"
bash "$CLEAR" force-push >/dev/null 2>&1
fp="$(read_care '.gate_cleared["force-push"].until // "null"')"
gp="$(read_care '.gate_cleared["git-push"].until // "null"')"
assert_ne "$fp" "null" "force-push present"

test_start "git-push token still present alongside force-push"
assert_ne "$gp" "null" "git-push present"

# ── R2 follow-up: clear-gate must VERIFY its write before claiming success ──
# It used to print "gate cleared" and log the trace UNCONDITIONALLY, even when the
# jq write failed — the same assert-without-verify pattern Maude's own tripwire
# catches. A write failure is forced deterministically (even under root) by making
# care.json a DIRECTORY, so nothing can redirect-write to that path.
force_write_fail() { rm -rf "$(care_path)"; mkdir -p "$(care_path)"; }
undo_write_fail()  { rm -rf "$(care_path)"; }

test_start "clear-gate does NOT claim success when the care.json write fails"
force_write_fail
OUT="$(bash "$CLEAR" git-push 2>/dev/null)"
undo_write_fail
assert_not_contains "$OUT" "gate cleared" "no false success"

test_start "clear-gate exits non-zero when the write fails"
force_write_fail
bash "$CLEAR" git-push >/dev/null 2>&1
RC=$?
undo_write_fail
assert_exit "$RC" "1" "write failure → exit 1"

test_start "clear-gate reports the failure on stderr"
force_write_fail
ERR="$(bash "$CLEAR" git-push 2>&1 >/dev/null)"
undo_write_fail
assert_contains "$ERR" "could NOT" "honest failure message"

test_start "clear-gate does NOT log a gate-cleared trace on write failure"
: > "$(trace_path)"
force_write_fail
bash "$CLEAR" git-push >/dev/null 2>&1
undo_write_fail
n="$(count_trace_lines '.kind == "gate-cleared"')"
assert_eq "$n" "0" "no false gate-cleared trace"

print_summary
teardown_test_env
exit $FAILED
