#!/usr/bin/env bash
# Tests for hooks/scripts/maude-memory-budget.sh — the auto-memory index budget.
#
# Claude Code loads <slug>/memory/MEMORY.md whole at every session start, so every unit in
# it is rent paid by every session. A whisper after the write did not hold it down: on the
# box this was built on the index sat at its 25,000-unit cap through 54 trims. The rail
# now refuses a Write/Edit/MultiEdit that would GROW the index past its budget (a shrinking
# edit always passes), and says so on every prompt while the index is over, which is the
# only net for a write made through Bash.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

MB="$HOOKS_DIR/maude-memory-budget.sh"
PRE="$HOOKS_DIR/maude-pre-tool-use.sh"
UPS="$HOOKS_DIR/maude-user-prompt-submit.sh"
IDX="$TEST_TMP/.claude/projects/-x/memory/MEMORY.md"

mk_text() { python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write(('- a line\n' * (n // 9 + 1))[:n])" "$1"; }
mk_index() { mkdir -p "$(dirname "$1")"; mk_text "$2" > "$1"; }
# Content goes through files, not --arg: one command-line argument holds 128 KiB at most,
# and the large-input tests below need more than that to reach the gate at all.
write_input() {  # $1 path, $2 content
  printf '%s' "$2" > "$TEST_TMP/.c"
  jq -nc --arg fp "$1" --rawfile c "$TEST_TMP/.c" '{tool_name:"Write", tool_input:{file_path:$fp, content:$c}}'
}
edit_input() {  # $1 path, $2 old, $3 new, [$4 replace_all]
  printf '%s' "$3" > "$TEST_TMP/.n"
  jq -nc --arg fp "$1" --arg o "$2" --rawfile n "$TEST_TMP/.n" --argjson ra "${4:-false}" \
    '{tool_name:"Edit", tool_input:{file_path:$fp, old_string:$o, new_string:$n, replace_all:$ra}}'
}
# Called directly the gate refuses with 42; maude-pre-tool-use.sh turns 42 (only) into 2.
gate() { ERR="$(printf '%s' "$1" | bash "$MB" gate 2>&1 >/dev/null)"; RC=$?; }

# ── the budget ─────────────────────────────────────────────────────────────────────
test_start "default budget is 23,500 units: just under the loader's cut"
source_common
assert_eq "$(maude_memory_budget)" "23500" "default"

test_start "gate-config memory_index_budget sets it"
printf '{"memory_index_budget": 10000}\n' > "$MAUDE_GATE_CONFIG"
assert_eq "$(maude_memory_budget)" "10000" "from config"

test_start "a budget that is not a whole number of at least 1,000 falls back to the default"
for bad in '"10000"' '-5' '999' '1.5' '10000.5' 'null' '"x"'; do
  printf '{"memory_index_budget": %s}\n' "$bad" > "$MAUDE_GATE_CONFIG"
  assert_eq "$(maude_memory_budget)" "23500" "rejects $bad"
done
printf '{"memory_index_budget": 10000}\n' > "$MAUDE_GATE_CONFIG"

# ── Write ──────────────────────────────────────────────────────────────────────────
test_start "a Write that would put the index past its budget is refused, with the numbers"
mk_index "$IDX" 9000
gate "$(write_input "$IDX" "$(mk_text 12000)")"
assert_exit "$RC" "42" "blocked"
assert_contains "$ERR" "MEMORY.md" "names the file"
assert_contains "$ERR" "12000" "what it would be"
assert_contains "$ERR" "10000" "the budget"
assert_contains "$ERR" "9000" "what it is now"

test_start "a Write that stays under the budget passes"
gate "$(write_input "$IDX" "$(mk_text 9500)")"
assert_exit "$RC" "0" "passes"
assert_eq "$ERR" "" "silent"

test_start "a Write that shrinks an index already over the budget passes"
mk_index "$IDX" 20000
gate "$(write_input "$IDX" "$(mk_text 15000)")"
assert_exit "$RC" "0" "a trim is never refused"

test_start "a Write that creates the index past the budget is refused"
rm -f "$IDX"
gate "$(write_input "$IDX" "$(mk_text 11000)")"
assert_exit "$RC" "42" "blocked from nothing"

# ── Edit and MultiEdit: the gate judges the file the edit would leave ────────────────
test_start "an Edit that grows the index past its budget is refused"
mk_index "$IDX" 9990
gate "$(edit_input "$IDX" "- a line" "- a line that is now much longer than it was")"
assert_exit "$RC" "42" "blocked"

test_start "an Edit that grows it but stays under passes"
mk_index "$IDX" 5000
gate "$(edit_input "$IDX" "- a line" "- a longer line")"
assert_exit "$RC" "0" "passes"

test_start "replace_all is applied: one replacement passes, all of them would not"
mk_index "$IDX" 9000
gate "$(edit_input "$IDX" "- a line" "- a line, x")"
assert_exit "$RC" "0" "one replacement: 9,003"
gate "$(edit_input "$IDX" "- a line" "- a line, x" true)"
assert_exit "$RC" "42" "every one: 12,000 or so"

test_start "an Edit that shrinks an index already over passes"
mk_index "$IDX" 20000
gate "$(edit_input "$IDX" "- a line" "-" true)"
assert_exit "$RC" "0" "a trim is never refused"

test_start "an Edit whose old_string is not there is the tool's to refuse, not the gate's"
mk_index "$IDX" 9990
gate "$(edit_input "$IDX" "not in the file" "$(mk_text 5000)")"
assert_exit "$RC" "0" "passes to the tool"

test_start "an empty old_string is the tool's to refuse, not read as an insert"
mk_index "$IDX" 10000  # at the budget: the one inserted unit would cross it
gate "$(edit_input "$IDX" "" "x")"
assert_exit "$RC" "0" "passes to the tool"

test_start "a MultiEdit applies its edits in order before judging"
mk_index "$IDX" 9900
MULTI="$(jq -nc --arg fp "$IDX" '{tool_name:"MultiEdit", tool_input:{file_path:$fp, edits:[
  {old_string:"- a line", new_string:"- b line"}, {old_string:"- b line", new_string:"- b line plus two hundred units of new text, '"$(printf 'x%.0s' $(seq 1 200))"'"}]}}')"
gate "$MULTI"
assert_exit "$RC" "42" "the second edit only matches after the first"

# ── what the gate is not about ───────────────────────────────────────────────────────
test_start "a MEMORY.md that is not the auto-memory index is not gated"
mkdir -p "$TEST_TMP/elsewhere/memory"
gate "$(write_input "$TEST_TMP/elsewhere/memory/MEMORY.md" "$(mk_text 30000)")"
assert_exit "$RC" "0" "not under .claude/projects/"
gate "$(write_input "$TEST_TMP/.claude/projects/-x/memory/other.md" "$(mk_text 30000)")"
assert_exit "$RC" "0" "a topic file is free to be long"

test_start "the measure is UTF-16 units, not bytes: 4,000 emoji are 8,000 units and pass a 10,000 budget"
mk_index "$IDX" 100
gate "$(write_input "$IDX" "$(python3 -c "import sys; sys.stdout.write('\U0001F600' * 4000)")")"
assert_exit "$RC" "0" "16,000 bytes, 8,000 units"

test_start "…and not characters: 6,000 emoji are 12,000 units and are refused"
gate "$(write_input "$IDX" "$(python3 -c "import sys; sys.stdout.write('\U0001F600' * 6000)")")"
assert_exit "$RC" "42" "6,000 characters, 12,000 units"

test_start "input that is not JSON, or a tool it does not judge, passes"
gate "not json"
assert_exit "$RC" "0" "garbage"
gate "$(jq -nc --arg fp "$IDX" '{tool_name:"Read", tool_input:{file_path:$fp}}')"
assert_exit "$RC" "0" "Read"

# ── wired in: the Write/Edit hook refuses, the prompt hook speaks ─────────────────────
test_start "the pre-tool-use hook refuses through the gate (exit 2), before the undo snapshot"
mk_index "$IDX" 9000
ERR="$(write_input "$IDX" "$(mk_text 12000)" | bash "$PRE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked through the wrapper"
assert_contains "$ERR" "budget" "says why"

test_start "the pre-tool-use hook passes an ordinary write"
ERR="$(write_input "$TEST_TMP/notes.md" "hello" | bash "$PRE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "passes"

test_start "the prompt hook speaks while this project's index is over budget, with no house-map"
export MAUDE_MEM_DIR_OVERRIDE="$TEST_TMP/.claude/projects/-x/memory"
mk_index "$IDX" 12000
OUT="$(printf '{"prompt":"hi"}' | bash "$UPS" 2>/dev/null)"
assert_contains "$OUT" "MEMORY.md" "names the file"
assert_contains "$OUT" "12000" "the size"
assert_contains "$OUT" "10000" "the budget"

test_start "the prompt hook is silent when the index is under budget, or absent"
mk_index "$IDX" 8000
OUT="$(printf '{"prompt":"hi"}' | bash "$UPS" 2>/dev/null)"
assert_not_contains "$OUT" "MEMORY.md" "under"
rm -f "$IDX"
OUT="$(printf '{"prompt":"hi"}' | bash "$UPS" 2>/dev/null)"
assert_not_contains "$OUT" "MEMORY.md" "absent"
unset MAUDE_MEM_DIR_OVERRIDE

test_start "the post-write whisper reads the same budget"
mk_index "$IDX" 10500
ERR="$(make_edit_tool_input "$IDX" | bash "$HOOKS_DIR/maude-post-tool-use.sh" 2>&1 >/dev/null)"
assert_contains "$ERR" "budget of 10000" "configured budget, not its own number"
mk_index "$IDX" 9500
ERR="$(make_edit_tool_input "$IDX" | bash "$HOOKS_DIR/maude-post-tool-use.sh" 2>&1 >/dev/null)"
assert_not_contains "$ERR" "MEMORY.md" "under it: silent"

# ── lens 1 on 773da0e ─────────────────────────────────────────────────────────────
test_start "a missing or broken gate script never blocks a write (bash exits 2 on a syntax error)"
cp -R "$HOOKS_DIR" "$TEST_TMP/hooks-copy"
mk_index "$IDX" 9000
rm -f "$TEST_TMP/hooks-copy/maude-memory-budget.sh"
write_input "$TEST_TMP/notes.md" "hi" | bash "$TEST_TMP/hooks-copy/maude-pre-tool-use.sh" >/dev/null 2>&1
assert_exit "$?" "0" "missing: an ordinary write passes"
write_input "$IDX" "$(mk_text 12000)" | bash "$TEST_TMP/hooks-copy/maude-pre-tool-use.sh" >/dev/null 2>&1
assert_exit "$?" "0" "missing: fails open"
printf 'if then fi(\n' > "$TEST_TMP/hooks-copy/maude-memory-budget.sh"
write_input "$TEST_TMP/notes.md" "hi" | bash "$TEST_TMP/hooks-copy/maude-pre-tool-use.sh" >/dev/null 2>&1
assert_exit "$?" "0" "syntax error: an ordinary write passes"
rm -rf "$TEST_TMP/hooks-copy"

test_start "a write too large for an environment variable (past 128 KiB) is still judged"
mk_index "$IDX" 9000
gate "$(write_input "$IDX" "$(mk_text 200000)")"
assert_exit "$RC" "42" "200 KB of content is refused, not waved through"
gate "$(edit_input "$IDX" "- a line" "$(mk_text 200000)")"
assert_exit "$RC" "42" "a 200 KB new_string too"

test_start "a whole-number budget in any JSON spelling is read as that number"
for spelled in '1e4' '10000.0' '1E4'; do
  printf '{"memory_index_budget": %s}\n' "$spelled" > "$MAUDE_GATE_CONFIG"
  assert_eq "$(maude_memory_budget)" "10000" "$spelled"
done
printf '{"memory_index_budget": 1e300}\n' > "$MAUDE_GATE_CONFIG"
assert_eq "$(maude_memory_budget)" "23500" "past what a shell integer holds: the default, never a broken number"
printf '{"memory_index_budget": 12345678901234567890}\n' > "$MAUDE_GATE_CONFIG"
assert_eq "$(maude_memory_budget)" "23500" "jq prints this one as 20 digits: past a shell integer, so the default (lens 2)"
printf '{"memory_index_budget": 10000}\n' > "$MAUDE_GATE_CONFIG"

test_start "CRLF counts the way the loader counts: \\r\\n is two units"
python3 -c "import sys; sys.stdout.write('a' * 98 + '\\r\\n')" > /dev/null
python3 -c "
import sys
with open(sys.argv[1], 'w', newline='') as f: f.write(('a' * 98 + '\\r\\n') * 100)" "$IDX"
gate "$(edit_input "$IDX" "aaaa" "aaaab")"
assert_exit "$RC" "42" "10,000 units with the CRs, one more is over"
OUT="$(bash "$MB" prompt "$IDX")"
assert_eq "$OUT" "" "exactly at the budget: silent"
python3 -c "
import sys
with open(sys.argv[1], 'w', newline='') as f: f.write(('a' * 98 + '\\r\\n') * 101)" "$IDX"
OUT="$(bash "$MB" prompt "$IDX")"
assert_contains "$OUT" "10100 units" "over: the loader's count"

test_start "only a real <slug>/memory/MEMORY.md is the index: a slug holds no slash"
gate "$(write_input "$TEST_TMP/.claude/projects/a/b/memory/MEMORY.md" "$(mk_text 30000)")"
assert_exit "$RC" "0" "nested: not the index"

test_start "something at the index path that is not a regular file is never opened (a FIFO would hang)"
rm -f "$IDX"; mkfifo "$IDX"
printf '%s' "$(write_input "$IDX" "$(mk_text 12000)")" | timeout 10 bash "$MB" gate >/dev/null 2>&1
assert_exit "$?" "0" "a FIFO: passes at once, no hang"
rm -f "$IDX"

test_start "at exactly the budget all three agree it is not over"
mk_index "$IDX" 10000
ERR="$(make_edit_tool_input "$IDX" | bash "$HOOKS_DIR/maude-post-tool-use.sh" 2>&1 >/dev/null)"
assert_not_contains "$ERR" "MEMORY.md" "post-write: silent at the budget"
assert_eq "$(bash "$MB" prompt "$IDX")" "" "prompt: silent at the budget"

test_start "a python module in the project directory is never imported by the gate (isolated mode)"
mkdir -p "$TEST_TMP/proj"
printf 'import pathlib\npathlib.Path(%s).write_text("ran")\nfrom json import *\n' "'$TEST_TMP/proj/PWNED'" > "$TEST_TMP/proj/json.py"
cp "$TEST_TMP/proj/json.py" "$TEST_TMP/proj/os.py"
mk_index "$IDX" 9000
(cd "$TEST_TMP/proj" && write_input "$IDX" "$(mk_text 12000)" | bash "$MB" gate >/dev/null 2>&1)
(cd "$TEST_TMP/proj" && bash "$MB" prompt "$IDX" >/dev/null 2>&1)
assert_file_absent "$TEST_TMP/proj/PWNED" "no planted module ran"

print_summary
teardown_test_env
exit $FAILED
