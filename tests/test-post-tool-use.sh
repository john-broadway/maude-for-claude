#!/usr/bin/env bash
# Tests for hooks/scripts/maude-post-tool-use.sh — watched-path tracking.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

POST="$HOOKS_DIR/maude-post-tool-use.sh"

run_post() {
  local fp="$1"
  make_edit_tool_input "$fp" | bash "$POST" >/dev/null 2>&1
  RC=$?
}

# Without house-map, hook is a no-op
test_start "post-tool-use silent without house-map"
run_post "$TEST_TMP/foo.txt"
assert_exit "$RC" "0" "exit"
n="$(count_trace_lines '.kind == "post-tool"')"
assert_eq "$n" "0" "no trace event"

# With house-map containing watch list
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map
## Watch list
- CLAUDE.md
- settings.json
EOF

test_start "post-tool logs trace when target hits watch term"
run_post "$TEST_TMP/.claude/CLAUDE.md"
n="$(count_trace_lines '.kind == "post-tool"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged on watch hit"

test_start "post-tool silent when target NOT on watch list"
: > "$(trace_path)"
run_post "$TEST_TMP/random/file.py"
n="$(count_trace_lines '.kind == "post-tool"')"
assert_eq "$n" "0" "no trace on miss"

test_start "post-tool always exits 0"
run_post "$TEST_TMP/random.txt"
assert_exit "$RC" "0" "exit"

test_start "post-tool handles empty stdin"
printf '' | bash "$POST" >/dev/null 2>&1
RC=$?
assert_exit "$RC" "0" "empty stdin"


# ── the auto-memory index has a load limit; say so at the write, not the next wake ──────
# Claude Code loads ~/.claude/projects/<slug>/memory/MEMORY.md at session start and stops
# past ~24.4 KB, measured in UTF-16 units (JavaScript's string length: an emoji counts 2,
# a byte count overstates, a character count understates). The cut prints one line into
# the transcript and nothing else; on this box the index sat over the limit for two
# sessions (2026-09-05/06) and the laws at its tail never loaded. A whisper at the write
# is the rail. Fires with or without a house-map, like the rules rail above it.
mk_index() {  # $1 = path, $2 = UTF-16 units (ASCII, so units == bytes)
  mkdir -p "$(dirname "$1")"
  python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write(('- a law line\n' * (n // 13 + 1))[:n])" "$2" > "$1"
}
run_post_err() { ERR="$(make_edit_tool_input "$1" | bash "$POST" 2>&1 >/dev/null)"; }
IDX="$TEST_TMP/.claude/projects/-root-projects/memory/MEMORY.md"

test_start "a MEMORY.md written OVER the load limit gets the whisper, with the numbers"
mk_index "$IDX" 25200
run_post_err "$IDX"
assert_contains "$ERR" "MEMORY.md" "names the file"
assert_contains "$ERR" "24.6 KB" "says the measured size (25,200 units)"
assert_contains "$ERR" "24.4 KB" "and the limit"

test_start "a MEMORY.md within 6% of the limit gets the whisper too"
mk_index "$IDX" 23900
run_post_err "$IDX"
assert_contains "$ERR" "MEMORY.md" "near-limit whisper"

test_start "a MEMORY.md comfortably under is silent"
mk_index "$IDX" 20000
run_post_err "$IDX"
assert_eq "$ERR" "" "silent"

test_start "the measure is UTF-16 units, not bytes: 8,000 emoji = 32,000 bytes = 16,000 units, silent"
mkdir -p "$(dirname "$IDX")"; python3 -c "import sys; sys.stdout.write('\U0001F600' * 8000)" > "$IDX"
run_post_err "$IDX"
assert_eq "$ERR" "" "bytes would have whispered; units do not"

test_start "…and not characters: 12,600 emoji = 12,600 chars = 25,200 units, whispers"
python3 -c "import sys; sys.stdout.write('\U0001F600' * 12600)" > "$IDX"
run_post_err "$IDX"
assert_contains "$ERR" "MEMORY.md" "chars would have stayed silent; units whisper"

test_start "a MEMORY.md that is not under a memory/ dir is not the index: silent"
mk_index "$TEST_TMP/elsewhere/MEMORY.md" 25200
run_post_err "$TEST_TMP/elsewhere/MEMORY.md"
assert_eq "$ERR" "" "silent"

test_start "a memory/MEMORY.md that is not under a .claude/projects/ dir is not the index: silent (24th lens, MINOR-8)"
mk_index "$TEST_TMP/notaclaude/memory/MEMORY.md" 25200
run_post_err "$TEST_TMP/notaclaude/memory/MEMORY.md"
assert_eq "$ERR" "" "the loader's limit does not apply to it"

test_start "a big file that is not MEMORY.md is silent"
mk_index "$TEST_TMP/projects/-root-projects/memory/now_wick.md" 40000
run_post_err "$TEST_TMP/projects/-root-projects/memory/now_wick.md"
assert_eq "$ERR" "" "silent"

print_summary
teardown_test_env
exit $FAILED
