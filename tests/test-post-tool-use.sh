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

print_summary
teardown_test_env
exit $FAILED
