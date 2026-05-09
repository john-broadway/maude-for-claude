#!/usr/bin/env bash
# Tests for hooks/scripts/maude-user-prompt-submit.sh — prompt vs watch-list nudge.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

UPS="$HOOKS_DIR/maude-user-prompt-submit.sh"

run_ups() {
  local prompt="$1"
  ERR="$(jq -nc --arg p "$prompt" '{prompt:$p}' | bash "$UPS" 2>&1 >/dev/null)"
  RC=$?
}

# No house-map → no-op
test_start "ups silent without house-map"
run_ups "anything"
assert_eq "$ERR" "" "silent"
assert_exit "$RC" "0" "exit"

# House-map with watch list
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map
## Watch list
- .claude/CLAUDE.md
- settings.json
EOF

test_start "ups warns when prompt mentions watched basename"
run_ups "let me edit CLAUDE.md"
assert_contains "$ERR" "CLAUDE.md" "warning fired"

test_start "ups warns case-insensitive"
run_ups "let me edit claude.md"
assert_contains "$ERR" "CLAUDE.md" "case insensitive"

test_start "ups silent when prompt unrelated to watched paths"
run_ups "hello world how are you"
assert_eq "$ERR" "" "no warning"

test_start "ups silent on empty prompt"
ERR="$(printf '{}' | bash "$UPS" 2>&1 >/dev/null)"
assert_eq "$ERR" "" "empty prompt"

test_start "ups exits 0 on multi-watch hit"
run_ups "edit settings.json AND CLAUDE.md"
RC=$?
assert_exit "$RC" "0" "exit"

print_summary
teardown_test_env
exit $FAILED
