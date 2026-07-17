#!/usr/bin/env bash
# tests/test-receipts.sh — /maude:receipts: the measured table (issue #43).
#
# Ponytail's rules, enforced as tests: friction never counts as value,
# no percentage without a denominator (so: no percentages at all), counts
# never content, the window is stated, and the reader is READ-ONLY (the
# digest advances a watermark; receipts must never touch state).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

RCPT="$SCRIPTS_DIR/maude-receipts.sh"
TDIR="$TEST_TMP/.maude/plugin/trace"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
mkdir -p "$TDIR"

ev() {  # ev <file-date> <ts> <kind> <payload>
  jq -nc --arg ts "$2" --arg kind "$3" --arg payload "$4" \
    '{ts:$ts,kind:$kind,payload:$payload}' >> "$TDIR/today-$1.jsonl"
}

# Planted history: two sole-copy saves, one reset-hard block, one infra block,
# one red-key clear refusal, two drift, one eye whisper; friction: three
# push-clears, four verify flags. One payload carries a marker that must
# NEVER surface (counts, not content).
ev 2026-06-01 2026-06-01T10:00:00Z gate "blocked=rm-rf-sole-copy target=SECRETMARKER-XYZ"
ev 2026-06-01 2026-06-01T11:00:00Z gate "blocked=rm-rf-sole-copy"
ev 2026-06-01 2026-06-01T12:00:00Z gate "blocked=reset-hard"
ev 2026-06-01 2026-06-01T13:00:00Z infra-gate "blocked tool=pve_delete_guest"
ev 2026-06-01 2026-06-01T14:00:00Z gate-clear-refused "key=force-push"
ev 2026-06-01 2026-06-01T15:00:00Z drift "repeat=Bash"
ev 2026-06-01 2026-06-01T16:00:00Z eye "whisper shown"
ev 2026-06-01 2026-06-01T17:00:00Z gate "blocked=git-push"
ev 2026-06-01 2026-06-01T17:01:00Z gate-cleared "git-push"
TODAY="$(date -u +%Y-%m-%d)"
ev "$TODAY" "${TODAY}T01:00:00Z" drift "repeat=Edit"
ev "$TODAY" "${TODAY}T02:00:00Z" gate-cleared "git-push"
ev "$TODAY" "${TODAY}T03:00:00Z" gate-cleared "git-push"
# verify events: TWO real whispers, TWO routine success stamps, ONE stamp
# failure — only the whispers may count as flags (review #1: stamps counted
# as flags inflated the headline number).
ev "$TODAY" "${TODAY}T04:01:00Z" verify "commit-without-verify whisper"
ev "$TODAY" "${TODAY}T04:02:00Z" verify "stop-without-verify whisper"
ev "$TODAY" "${TODAY}T04:03:00Z" verify "stamped last_verify_iso"
ev "$TODAY" "${TODAY}T04:04:00Z" verify "stamped last_verify_iso"
ev "$TODAY" "${TODAY}T04:05:00Z" verify "could not stamp last_verify_iso"
# a half-flushed corrupt line must not kill the table (review #5)
printf 'GARBAGE-NOT-JSON {{{\n' >> "$TDIR/today-$TODAY.jsonl"

jq -n '{
  "c1-missed-save": {status:"done", cost:{model:"haiku", runtime_s:16}},
  "c2-shelves":     {status:"done", cost:{model:"none", runtime_s:0}},
  "c3-extension":   {status:"failed", cost:{model:"none", runtime_s:1}},
  "c4-claudemd":    {status:"undone", cost:{model:"none", runtime_s:0}}
}' > "$LEDGER"

TREE_BEFORE="$(find "$TEST_TMP/.maude" -type f 2>/dev/null | sort)"
OUT="$(bash "$RCPT" 2>&1)"
RC=$?

test_start "receipts runs clean"
assert_exit "$RC" "0" "exit 0"

test_start "the window is stated from the actual trace"
if printf '%s' "$OUT" | grep -q '2026-06-01' && printf '%s' "$OUT" | grep -q "$TODAY"; then
  _pass
else
  _fail "window missing dates: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "sole-copy saves counted in their own class"
assert_contains "$OUT" "sole-copy" "sole-copy row present"

test_start "sole-copy count is 2"
if printf '%s' "$OUT" | grep -E 'sole-copy' | grep -q '2'; then _pass; else
  _fail "expected 2 in sole-copy row: $(printf '%s' "$OUT" | grep -i 'sole-copy')"; fi

test_start "red-key clear refusal counted"
assert_contains "$OUT" "red-key" "red-key refusal row"

test_start "push-clears labeled friction, never value"
LINE="$(printf '%s' "$OUT" | grep -i 'push-clear')"
if printf '%s' "$LINE" | grep -q '3' && printf '%s' "$OUT" | grep -qi 'friction'; then
  _pass
else
  _fail "push-clears not counted as labeled friction: $LINE"
fi

test_start "no percentages anywhere (no denominator, no percent)"
if printf '%s' "$OUT" | grep -q '%'; then
  _fail "found a percent sign: $(printf '%s' "$OUT" | grep '%' | head -1)"
else
  _pass
fi

test_start "the no-denominator rule is stated in the method note"
assert_contains "$OUT" "denominator" "method states the denominator rule"

test_start "counts never content — payload text does not surface"
assert_not_contains "$OUT" "SECRETMARKER-XYZ" "planted payload marker absent"

test_start "commit-whispers counted as value; stamps and stamp errors are NOT flags"
LINE="$(printf '%s' "$OUT" | grep -i 'commit-without-verify')"
if printf '%s' "$LINE" | grep -q '1'; then _pass; else
  _fail "expected 1 commit-whisper (not raw verify events): $LINE"; fi

test_start "stop-whispers fenced as repetition — one condition re-observed per turn"
LINE="$(printf '%s' "$OUT" | grep -i 'stop-without-verify')"
if [ -n "$LINE" ] && printf '%s' "$LINE" | grep -q '1' \
   && printf '%s' "$LINE" | grep -qiE 're-observed|repetition'; then
  _pass
else
  _fail "stop-whispers not fenced with the repetition note: $LINE"
fi

test_start "eye row says what it is — whispers dropped stale, not shown-and-ignored"
LINE="$(printf '%s' "$OUT" | grep -i 'stale whisper')"
if [ -n "$LINE" ] && printf '%s' "$LINE" | grep -q '1' \
   && ! printf '%s' "$OUT" | grep -qi 'includes ones that were ignored'; then
  _pass
else
  _fail "eye row mislabeled: $(printf '%s' "$OUT" | grep -i 'whisper' | head -2)"
fi

test_start "a corrupt trace line is skipped, counted, and stated — table survives"
if printf '%s' "$OUT" | grep -E 'sole-copy' | grep -q '2' \
   && printf '%s' "$OUT" | grep -qi 'malformed'; then
  _pass
else
  _fail "corrupt line killed or silently skipped: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "chores: every ledger status counted — the sentence sums to the stamps"
if printf '%s' "$OUT" | grep -q '2 done' && printf '%s' "$OUT" | grep -q '1 undone' \
   && printf '%s' "$OUT" | grep -q '1 failed'; then
  _pass
else
  _fail "chore statuses wrong: $(printf '%s' "$OUT" | grep -i chore)"
fi

test_start "receipts is READ-ONLY — the whole .maude tree is untouched"
TREE_AFTER="$(find "$TEST_TMP/.maude" -type f 2>/dev/null | sort)"
assert_eq "$TREE_AFTER" "$TREE_BEFORE" "no file created or removed anywhere under .maude"

test_start "--days with a leading zero is decimal, never octal, never an error"
OUT8="$(bash "$RCPT" --days 008 2>&1)"
RC8=$?
if [ "$RC8" -eq 0 ] && ! printf '%s' "$OUT8" | grep -qi 'value too great'; then
  _pass
else
  _fail "leading-zero days broke: rc=$RC8 $(printf '%s' "$OUT8" | head -c 150)"
fi

test_start "--days narrows the window (old file excluded)"
OUT7="$(bash "$RCPT" --days 7 2>&1)"
if printf '%s' "$OUT7" | grep -E 'sole-copy' | grep -q '0'; then
  _pass
else
  _fail "old sole-copy events leaked into 7-day window: $(printf '%s' "$OUT7" | grep -i 'sole-copy')"
fi

test_start "jq absent → graceful note, rc 0"
NOJQ="$(make_nojq_bin)"
OUTNJ="$(PATH="$NOJQ" bash "$RCPT" 2>&1)"
RC=$?
rm -rf "$NOJQ"
if [ "$RC" -eq 0 ] && printf '%s' "$OUTNJ" | grep -qi 'jq'; then _pass; else
  _fail "expected graceful jq note rc=0, got rc=$RC: $(printf '%s' "$OUTNJ" | head -c 120)"; fi

teardown_test_env
print_summary
exit "$FAILED"
