#!/usr/bin/env bash
# Tests for maude_python3_ok — python3 discovery must EXECUTE a probe, not test
# for presence. Earned 2026-08-22: on Windows, `python3.exe` resolves to the
# Microsoft Store alias stub (WindowsApps), which `command -v` happily finds and
# which then fails at execution (exit 9009 / opens the Store). A probe that
# returns the same answer whether the interpreter works or not is not a check.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

COMMON="$HOOKS_DIR/_maude-common.sh"

# A fake bin dir whose python3 is present but broken — the Store-alias shape.
STUB_BIN="$TEST_TMP/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 9009\n' > "$STUB_BIN/python3"
chmod +x "$STUB_BIN/python3"
# The stub PATH still needs the baseline utilities the common lib leans on.
for t in bash sh cat grep sed awk printf env dirname basename mktemp rm mkdir date; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$STUB_BIN/$t"
done

test_start "maude_python3_ok exists"
bash -c ". '$COMMON'; type maude_python3_ok" >/dev/null 2>&1
assert_exit "$?" "0" "helper defined in _maude-common.sh"

test_start "maude_python3_ok passes with a real python3"
bash -c ". '$COMMON'; maude_python3_ok" >/dev/null 2>&1
assert_exit "$?" "0" "real interpreter probes OK"

test_start "maude_python3_ok fails on a present-but-broken python3 (Store alias shape)"
env PATH="$STUB_BIN" bash -c ". '$COMMON'; maude_python3_ok" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ]
assert_exit "$?" "0" "stub interpreter reads as absent (got rc=$rc)"

test_start "session-start names a broken python3 (the degradation is announced, not silent)"
err="$(printf '{"session_id":"t1","hook_event_name":"SessionStart","source":"startup"}' \
  | env PATH="$STUB_BIN" CLAUDE_PROJECT_DIR="$TEST_TMP" CLAUDE_PLUGIN_ROOT="$MAUDE_ROOT" \
    bash "$HOOKS_DIR/maude-session-start.sh" 2>&1 >/dev/null)"
case "$err" in
  *"python3 is missing or not working"*) ok=0 ;;
  *) ok=1 ;;
esac
assert_exit "$ok" "0" "whisper present on stub interpreter (stderr: $err)"

test_start "session-start stays quiet about python3 when it works"
err="$(printf '{"session_id":"t1","hook_event_name":"SessionStart","source":"startup"}' \
  | env CLAUDE_PROJECT_DIR="$TEST_TMP" CLAUDE_PLUGIN_ROOT="$MAUDE_ROOT" PATH="$PATH" \
    bash "$HOOKS_DIR/maude-session-start.sh" 2>&1 >/dev/null)"
case "$err" in
  *"python3 is missing or not working"*) ok=1 ;;
  *) ok=0 ;;
esac
assert_exit "$ok" "0" "no whisper with a real interpreter (stderr: $err)"

test_start "no hook script tests python3 by presence any more"
# The class fix: every python3 gate goes through maude_python3_ok. A bare
# `command -v python3` presence test is the defect shape — forbid it outside
# this test file.
# Comment lines are exempt — the helper's own doc names the forbidden idiom
# (writing about a text-scanned trap writes into it).
hits="$(grep -rn "command -v python3" "$HOOKS_DIR" 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#')"
assert_eq "$hits" "" "no 'command -v python3' in hooks/scripts (found: $hits)"

teardown_test_env
exit "$FAILED"
