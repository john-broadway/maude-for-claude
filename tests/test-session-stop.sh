#!/usr/bin/env bash
# Tests for hooks/scripts/maude-session-stop.sh — minimal trace-event-only Stop hook.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

STOP="$HOOKS_DIR/maude-session-stop.sh"

test_start "session-stop exits 0"
RC="$(printf '{}' | bash "$STOP" >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "exit"

test_start "session-stop logs a stop event"
n="$(count_trace_lines '.kind == "stop"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

# Verify it does NOT clobber .remember/remember.md (yesterday's regression)
mkdir -p "$TEST_TMP/.remember"
cat > "$TEST_TMP/.remember/remember.md" <<'EOF'
# Existing handoff
EOF
EXISTING="$(cat "$TEST_TMP/.remember/remember.md")"

test_start "session-stop does NOT touch .remember/remember.md"
printf '{}' | bash "$STOP" >/dev/null 2>&1
NOW="$(cat "$TEST_TMP/.remember/remember.md")"
assert_eq "$NOW" "$EXISTING" "remember.md untouched"

# Verify it does NOT append to recent.md
test_start "session-stop does NOT append to recent.md"
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEM"
: > "$MEM/recent.md"
printf '{}' | bash "$STOP" >/dev/null 2>&1
[ ! -s "$MEM/recent.md" ]
assert_exit "$?" "0" "recent.md still empty"

rm -rf "$MEM"

test_start "session-stop emits no stderr"
ERR="$(printf '{}' | bash "$STOP" 2>&1 >/dev/null)"
assert_eq "$ERR" "" "silent"

print_summary
teardown_test_env
exit $FAILED
