#!/usr/bin/env bash
# tests/test-chores-c1-save.sh — save doer: substrate guard, stub blink, redaction, append-only, failure.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"

printf '{"type":"user","message":{"role":"user","content":"build the ledger"}}\n' > "$TEST_TMP/t.jsonl"

# ── Critical 3: no .remember/ substrate → c1 never due, doer no-ops safely,
# and .remember/ is never manufactured uninvited. setup_test_env creates
# .maude/plugin/ only — NO .remember/ exists yet at this point in the file.
TRACE="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
for _ in 1 2 3 4 5 6 7; do
  printf '{"ts":"%s","kind":"prompt","hook":"UserPromptSubmit","tool":null,"target":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
done

test_start "c1 not due when .remember/ absent"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].due' "$LEDGER")" "false" "c1 not due when .remember/ absent"

test_start "forced run: status undone when .remember/ absent"
bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].status' "$LEDGER")" "undone" "forced run status undone"

test_start "forced run: note names the substrate"
assert_contains "$(jq -r '.["c1-missed-save"].note' "$LEDGER")" "substrate" "forced run note names substrate"

test_start "forced run: .remember/ NOT manufactured"
assert_file_absent "$TEST_TMP/.remember" ".remember/ not manufactured"

# ── From here on the project HAS opted into the .remember/ substrate ──
mkdir -p "$TEST_TMP/.remember"
REMEMBER="$TEST_TMP/.remember/remember.md"

# Stub blink emits a digest containing a redactable marker.
STUB="$TEST_TMP/stub-blink"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'DONE: built ledger at 192.0.2.71\nOPEN: wire brief\n'
EOF
chmod +x "$STUB"

test_start "doer writes remember.md when empty"
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_contains "$(cat "$REMEMBER" 2>/dev/null)" "built ledger" "doer writes remember.md when empty"

test_start "redaction applied before disk"
assert_not_contains "$(cat "$REMEMBER")" "192.0.2.71" "redaction applied before disk"

test_start "ledger stamped done with cost"
assert_eq "$(jq -r '.["c1-missed-save"].status' "$LEDGER")" "done" "ledger stamped done"

test_start "cost stamp has model"
assert_eq "$(jq -r '.["c1-missed-save"].cost.model' "$LEDGER")" "stub" "cost stamp has model"

test_start "closet copy exists"
assert_file_exists "$TEST_TMP/.maude/plugin/chore-c1-latest.md" "closet copy exists"

# Fresh human handoff (mtime now, anchor 0) → append, never replace.
printf '# handoff by John\nkeep me\n' > "$REMEMBER"
touch "$REMEMBER"
test_start "fresher remember.md gets append not replace"
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_contains "$(cat "$REMEMBER")" "keep me" "fresher remember.md keeps human content"

test_start "append lands under Maude heading"
assert_contains "$(cat "$REMEMBER")" "## Maude" "append lands under Maude heading"

# Critical 1 regression — the anchor-mtime race. maude_capture_anchor_epoch
# takes a 3-way max over $mem/now.md, .remember/now.md, and .remember/remember.md
# itself — so remember.md's OWN mtime was one of the 3 inputs the old code
# compared it against. A fresh human remember.md (mtime T) followed by ANY
# touch of a SIBLING anchor source (mtime > T) always made the anchor "newer
# than the handoff" under the old tri-state, and the doer replaced it —
# destroying the human content. Reproduce that exact shape here: remember.md
# older, .remember/now.md newer.
NOWEPOCH="$(date +%s)"
printf '# handoff by John\nrace-survivor content\n' > "$REMEMBER"
touch -d "@$((NOWEPOCH - 100))" "$REMEMBER"
printf 'in progress\n' > "$TEST_TMP/.remember/now.md"
touch -d "@$NOWEPOCH" "$TEST_TMP/.remember/now.md"
test_start "race: touching a newer anchor sibling after a fresh remember.md must not replace it"
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_contains "$(cat "$REMEMBER")" "race-survivor content" "race: human content survives a newer anchor sibling"
assert_contains "$(cat "$REMEMBER")" "## Maude" "race: Maude's digest still appended"
rm -f "$TEST_TMP/.remember/now.md"

# Failing blink → failed stamp with reason.
test_start "blink failure stamps failed"
MAUDE_CHORE_RUNNER_OVERRIDE="/nonexistent-runner" bash "$CH" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_eq "$(jq -r '.["c1-missed-save"].status' "$LEDGER")" "failed" "blink failure stamps failed"

# Safety net: a doer that died before stamping leaves 'dispatched' — the net converts it.
test_start "safety net converts dispatched to failed"
(
  # shellcheck source=/dev/null
  MAUDE_CHORES_LIB=1 . "$CH"
  chore_stamp c1-missed-save --arg s dispatched '.["c1-missed-save"] += {status:$s}'
  chore_fail_if_unstamped c1-missed-save
)
assert_eq "$(jq -r '.["c1-missed-save"].status' "$LEDGER")" "failed" "safety net converts dispatched to failed"

test_start "safety net note says doer crashed"
assert_contains "$(jq -r '.["c1-missed-save"].note' "$LEDGER")" "doer crashed" "safety net note says doer crashed"

test_start "safety net preserves done"
(
  # shellcheck source=/dev/null
  MAUDE_CHORES_LIB=1 . "$CH"
  chore_stamp c1-missed-save --arg s "done" '.["c1-missed-save"] += {status:$s}'
  chore_fail_if_unstamped c1-missed-save
)
assert_eq "$(jq -r '.["c1-missed-save"].status' "$LEDGER")" "done" "safety net preserves done"

teardown_test_env
exit "$FAILED"
