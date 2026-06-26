#!/usr/bin/env bash
# Tests for maude_digest_line (in _maude-common.sh) — the session-start catch-digest:
# a one-line, JOHN-facing summary of what Maude caught since he last saw it.
#
# Watermark-based (last_digest_iso in care.json) so the digest doesn't re-print the
# same catches on every resume/compact (SessionStart fires on all of those).
# Sourced helper is the SUT; fixtures are a dated trace file + a seeded care.json.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

# The helper reads trace files whose filename-date >= the watermark's date, so the
# fixture day must be on/after the seeded watermark's day.
FIXDAY="2026-06-23"
TRACE="$TEST_TMP/.maude/plugin/trace/today-$FIXDAY.jsonl"

emit() {  # emit <ts> <kind> <payload>
  jq -nc --arg ts "$1" --arg kind "$2" --arg payload "$3" \
    '{ts:$ts,kind:$kind,payload:$payload}' >> "$TRACE"
}
reset_trace() { : > "$TRACE"; }
seed_care()   { printf '%s\n' "$1" > "$(care_path)"; }

# ── Scenario 1: first run (no watermark) seeds it, announces, no retro dump ──
reset_trace
emit "2026-06-23T01:00:00Z" "gate"  "blocked=rm-rf-sole-copy"
emit "2026-06-23T01:01:00Z" "drift" "kind=read target=x count=4"
seed_care '{}'
OUT1="$(maude_digest_line)"

test_start "first run announces the digest is on"
assert_contains "$OUT1" "digest" "armed line mentions digest"

test_start "first run does NOT retro-count old catches"
assert_not_contains "$OUT1" "sole-copy" "no retroactive counts on first run"

test_start "first run seeds the watermark"
assert_ne "$(read_care '.last_digest_iso')" "null" "last_digest_iso set"

# ── Scenario 2: counts catches since the watermark, value-first ──
reset_trace
emit "2026-06-23T10:00:00Z" "gate"         "blocked=rm-rf-sole-copy"     # the gold: a REAL sole-copy save
emit "2026-06-23T10:00:30Z" "gate"         "blocked=rm-rf-root"          # rm -rf / — a block, NOT a sole-copy save
emit "2026-06-23T10:01:00Z" "gate"         "blocked=drop-table"          # protective block
emit "2026-06-23T10:02:00Z" "gate"         "blocked=git-push"            # friction — NOT a block
emit "2026-06-23T10:03:00Z" "gate-cleared" "key=git-push duration=300"   # push-clear
emit "2026-06-23T10:04:00Z" "gate-cleared" "key=git-push duration=300"   # push-clear
emit "2026-06-23T10:05:00Z" "drift"        "kind=read target=s.py count=5"
emit "2026-06-23T10:06:00Z" "verify"       "stop"
emit "2026-06-23T10:07:00Z" "verify"       "stop"
emit "2026-06-23T10:08:00Z" "verify"       "commit"
seed_care '{"last_digest_iso":"2026-06-23T00:00:00Z","gate_cleared":{"git-push":{"until":9999999999}}}'
OUT2="$(maude_digest_line)"

test_start "value headline: sole-copy save, then blocks (rm-rf-root + drop-table), then drift"
assert_contains "$OUT2" "1 sole-copy save, 2 blocks, 1 drift-catch" "value headline grouped + ordered"

test_start "rm-rf-root is a block, NOT mislabeled as a sole-copy save"
assert_not_contains "$OUT2" "2 sole-copy" "only rm-rf-sole-copy counts as a sole-copy save"

test_start "git-push block is excluded (blocks stay at 2, not 3)"
assert_not_contains "$OUT2" "3 block" "git-push must not inflate the block count"

test_start "volume (push-clears + verify-flags) folds into a parenthetical tail"
assert_contains "$OUT2" "(+2 push-clears, 3 verify-flags)" "volume in the tail, after the value headline"

test_start "advances the watermark past the seed"
assert_ne "$(read_care '.last_digest_iso')" "2026-06-23T00:00:00Z" "watermark advanced"

test_start "preserves other care.json keys (conscience tokens)"
assert_eq "$(read_care '.gate_cleared["git-push"].until')" "9999999999" "gate_cleared survives"

# ── Scenario 3: nothing new since the watermark → silent (no line) ──
reset_trace
emit "2026-06-23T10:00:00Z" "gate" "blocked=rm-rf-sole-copy"
seed_care '{"last_digest_iso":"2026-06-23T23:59:59Z"}'
OUT3="$(maude_digest_line)"

test_start "silent when nothing caught since the watermark"
assert_eq "$OUT3" "" "no line when no new catches"

# ── Scenario 4: a lone git-push block (friction only) → silent ──
reset_trace
emit "2026-06-23T10:00:00Z" "gate" "blocked=git-push"
seed_care '{"last_digest_iso":"2026-06-23T00:00:00Z"}'
OUT4="$(maude_digest_line)"

test_start "a lone git-push block is not a catch (silent)"
assert_eq "$OUT4" "" "git-push block is not surfaced as a catch"

# ── Scenario 5: the session-start hook surfaces the digest on stdout (the John channel) ──
SS="$HOOKS_DIR/maude-session-start.sh"
reset_trace
emit "2026-06-23T10:00:00Z" "gate"  "blocked=rm-rf-sole-copy"
emit "2026-06-23T10:05:00Z" "drift" "kind=read target=s.py count=5"
seed_care '{"last_digest_iso":"2026-06-23T00:00:00Z"}'
OUT5="$(bash "$SS" 2>/dev/null)"

test_start "session-start hook emits the catch-digest line on stdout"
assert_contains "$OUT5" "Maude caught since you last looked" "digest surfaces in the brief"

test_start "session-start digest carries the real catch (sole-copy save)"
assert_contains "$OUT5" "1 sole-copy save" "the save reaches John"

# ── Scenario 6: volume-only window (no value catch) → shown plainly, no empty headline ──
reset_trace
emit "2026-06-23T10:00:00Z" "verify" "stop"
emit "2026-06-23T10:01:00Z" "verify" "stop"
seed_care '{"last_digest_iso":"2026-06-23T00:00:00Z"}'
OUT6="$(maude_digest_line)"

test_start "volume-only window shows the volume"
assert_contains "$OUT6" "2 verify-flags" "volume surfaced"

test_start "volume-only window has no dangling parenthetical tail"
assert_not_contains "$OUT6" "(+" "no '(+' when there is no value headline to append to"

print_summary
teardown_test_env
exit $FAILED
