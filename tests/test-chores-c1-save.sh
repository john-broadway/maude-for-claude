#!/usr/bin/env bash
# tests/test-chores-c1-save.sh: the c1 missed-save chore is RETIRED (2026-11-12).
#
# c1 asked a model (claude -p --model haiku) to write the handoff nobody typed into the
# remember plugin's remember.md. Maude no longer writes that store (the remember plugin's
# own /remember does), and John's 2026-10-25 ruling is "nothing needs to call out. SHE IS
# AUTONOMOUS": no model calls. Writing only to her closet, c1 stopped moving the capture
# anchor, so it stayed due and called the model on every Stop (review, 2026-11-12).
# Design: docs/specs/2026-11-11-the-circle-design.md (Non-goals: "The c1 chore's model
# call is retired"). The capability is re-homed: the continuity guard says uncaptured
# work at wake; phase 3's rest writes the lane entry.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"

mkdir -p "$TEST_TMP/.remember"
printf '{"type":"user","message":{"role":"user","content":"build the ledger"}}\n' > "$TEST_TMP/t.jsonl"
TRACE="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
mkdir -p "$(dirname "$TRACE")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '{"ts":"%s","kind":"prompt","hook":"UserPromptSubmit","tool":null,"target":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
done
MARK="$TEST_TMP/model-was-called"
STUB="$TEST_TMP/stub-blink"
printf '#!/usr/bin/env bash\ncat >/dev/null\ntouch "%s"\nprintf "DONE: x\\n"\n' "$MARK" > "$STUB"
chmod +x "$STUB"

test_start "c1 is never due, even with 10 uncaptured prompts and a remember store"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].due' "$LEDGER")" "false" "never due"

test_start "a forced run calls no model"
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_file_absent "$MARK" "no model call"

test_start "a forced run stamps the chore retired, and writes no closet digest"
assert_contains "$(jq -r '.["c1-missed-save"].note' "$LEDGER")" "retired" "note says retired"
assert_file_absent "$TEST_TMP/.maude/plugin/chore-c1-latest.md" "no digest file"

test_start "a dispatch after detect launches nothing for c1"
bash "$CH" detect >/dev/null 2>&1
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$CH" dispatch "$TEST_TMP/t.jsonl" >/dev/null 2>&1
sleep 1
assert_file_absent "$MARK" "no model call from dispatch"

print_summary
teardown_test_env
exit $FAILED
