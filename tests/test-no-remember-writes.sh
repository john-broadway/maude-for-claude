#!/usr/bin/env bash
# Maude never writes the remember plugin's store.
#
# The store belongs to the remember plugin (an official Claude Code plugin); its
# /remember writes the handoff, and its own pipeline writes the rest. On 2026-11-11
# 20:24Z a shared remember.md of ~3,900 lines was replaced with 35, and three of
# Maude's own writers (the pre-compact append, the session-end auto-note, the c1
# missed-save chore) also wrote into that file. Design: docs/specs/2026-11-11-the-circle-design.md
# ("What retires"; John's ruling 4: "keep it at its peak handling").
#
# The test fills a store, runs every Maude writer that used to touch it, and asserts
# every byte in the store is unchanged.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

R="$TEST_TMP/.remember"
mkdir -p "$R"
python3 -I -c 'import sys; open(sys.argv[1],"w").write("PRIOR HANDOFF\n"*4000)' "$R/remember.md"
printf 'buffer line\n' > "$R/now.md"
printf 'day\n' > "$R/today-2026-01-01.md"
touch -t 202601010000 "$R/remember.md" "$R/now.md" "$R/today-2026-01-01.md"   # old: the 600 s timer fires, and the prompts below count as uncaptured

TRACE="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
mkdir -p "$(dirname "$TRACE")"
for _ in 1 2 3 4 5 6 7; do
  printf '{"ts":"%s","kind":"prompt","hook":"UserPromptSubmit","tool":null,"target":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
done
printf '{"type":"user","message":{"role":"user","content":"build the ledger"}}\n' > "$TEST_TMP/t.jsonl"
STUB="$TEST_TMP/stub-blink"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "DONE: built ledger\\nOPEN: wire brief\\n"\n' > "$STUB"
chmod +x "$STUB"

sums() { (cd "$R" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done); }
BEFORE="$(sums)"

test_start "pre-compact leaves the remember store untouched"
printf '{"session_id":"s1","trigger":"auto"}' | bash "$HOOKS_DIR/maude-pre-compact.sh" >/dev/null 2>&1
assert_eq "$(sums)" "$BEFORE" "store bytes after pre-compact"

test_start "session-end leaves the remember store untouched, even with uncaptured work"
BEFORE="$(sums)"
printf '{"session_id":"s1","reason":"other"}' | bash "$HOOKS_DIR/maude-session-end.sh" >/dev/null 2>&1
assert_eq "$(sums)" "$BEFORE" "store bytes after session-end"

test_start "session-end with an EMPTY handoff slot still writes nothing there"
mv "$R/remember.md" "$TEST_TMP/held.md"
B2="$(sums)"
printf '{"session_id":"s1","reason":"other"}' | bash "$HOOKS_DIR/maude-session-end.sh" >/dev/null 2>&1
assert_eq "$(sums)" "$B2" "no auto-note written"
mv "$TEST_TMP/held.md" "$R/remember.md"

test_start "the c1 missed-save chore leaves the remember store untouched"
BEFORE="$(sums)"
MAUDE_CHORE_RUNNER_OVERRIDE="$STUB" bash "$SCRIPTS_DIR/maude-chores.sh" run c1-missed-save "$TEST_TMP/t.jsonl" >/dev/null 2>&1
assert_eq "$(sums)" "$BEFORE" "store bytes after c1"

test_start "the c2 re-roll, even switched on, moves and deletes nothing in the remember store"
printf 'old day\n' > "$R/today-2020-01-01.md"; touch -t 202001010000 "$R/today-2020-01-01.md"
BEFORE="$(sums)"
MAUDE_REROLL=on bash "$SCRIPTS_DIR/maude-chores.sh" run c2-shelves >/dev/null 2>&1
assert_eq "$(sums)" "$BEFORE" "store bytes after c2 with MAUDE_REROLL=on"
assert_file_absent "$R/archive" "no archive dir made in the store"

print_summary
teardown_test_env
exit $FAILED
