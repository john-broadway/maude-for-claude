#!/usr/bin/env bash
# Tests for hooks/scripts/maude-pre-compact.sh — snapshot before compaction.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

PC="$HOOKS_DIR/maude-pre-compact.sh"

run_pc() {
  ERR="$(printf '{}' | bash "$PC" 2>&1 >/dev/null)"
  RC=$?
}

# No live buffer — snapshot is a no-op but trace still fires
test_start "pre-compact exits 0 with no live buffer"
run_pc
assert_exit "$RC" "0" "exit"

test_start "pre-compact logs trace event"
n="$(count_trace_lines '.kind == "pre-compact"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

# With a live buffer (Anthropic memory now.md present)
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEM"
cat > "$MEM/now.md" <<'EOF'
## 18:00 | testing
Test buffer content for snapshot.
EOF

test_start "pre-compact creates snapshot when now.md exists"
run_pc
SNAPSHOT="$(ls "$TEST_TMP/.maude/plugin/snapshots/"precompact-*.md 2>/dev/null | head -1)"
[ -f "$SNAPSHOT" ]
assert_exit "$?" "0" "snapshot file created"

test_start "snapshot includes source content"
content="$(cat "$SNAPSHOT" 2>/dev/null)"
assert_contains "$content" "Test buffer content" "buffer copied"

test_start "pre-compact emits stderr note when snapshot taken"
assert_contains "$ERR" "snapshot" "stderr note"

# Cleanup MEM
rm -rf "$MEM"

print_summary
teardown_test_env
exit $FAILED
