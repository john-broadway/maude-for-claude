#!/usr/bin/env bash
# Tests for hooks/scripts/maude-session-start.sh — degradative session brief.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

START="$HOOKS_DIR/maude-session-start.sh"

run_start() {
  # session-start emits brief on stdout (not stderr — see script)
  OUT="$(printf '{}' | bash "$START" 2>/dev/null)"
  RC=$?
}

test_start "session-start exits 0"
run_start
assert_exit "$RC" "0" "exit"

# With nothing — silent
test_start "session-start silent with no memory anywhere"
# Make sure no Anthropic memory dir exists for this fake project slug
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
rm -rf "$HOME/.claude/projects/$SLUG"
run_start
# session-start may still print "Maude here" line if user-global patterns exist or
# memory dir exists with files — accept silent or minimal output.
[ -z "$OUT" ] || ! printf '%s' "$OUT" | grep -q "Anthropic now"
assert_exit "$?" "0" "no anthropic-now output"

# With house-map present
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map for test
## Watch list
EOF

test_start "session-start announces house-map ✓"
run_start
assert_contains "$OUT" "house-map" "map flagged"

# With Anthropic now.md present
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEM"
cat > "$MEM/now.md" <<'EOF'
## 18:00 | testing
First line of buffer content.
EOF

test_start "session-start surfaces Anthropic now line"
run_start
assert_contains "$OUT" "Anthropic now:" "now-line surfaced"

# With remember handoff
mkdir -p "$TEST_TMP/.remember"
cat > "$TEST_TMP/.remember/remember.md" <<'EOF'
# Handoff

## Next
The thing to do next is X.
EOF

test_start "session-start surfaces remember handoff"
run_start
assert_contains "$OUT" "Last handoff" "handoff surfaced"

# Cleanup
rm -rf "$MEM"

print_summary
teardown_test_env
exit $FAILED
