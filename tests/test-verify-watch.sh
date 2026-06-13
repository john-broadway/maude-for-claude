#!/usr/bin/env bash
# Tests for hooks/scripts/maude-verify-watch.sh — the assert-without-verify tripwire.
#   stamp  (PostToolUse·Bash) records an ISO ts when a real verify runs.
#   commit (PreToolUse·Bash) whispers once when CODE changed since the last verify.
# Always exits 0; whisper goes to stderr.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

VW="$HOOKS_DIR/maude-verify-watch.sh"

reset_care()  { printf '{}\n' > "$(care_path)"; }
set_care()    { printf '%s\n' "$1" > "$(care_path)"; }
set_trace()   { : > "$(trace_path)"; for l in "$@"; do printf '%s\n' "$l" >> "$(trace_path)"; done; }
do_stamp()    { make_bash_tool_input "$1" | bash "$VW" stamp >/dev/null 2>&1; }
run_commit()  { make_bash_tool_input "$1" | bash "$VW" commit 2>&1 >/dev/null; }

EDIT='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/foo.py"}'
DOC='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/README.md"}'

# ---- stamp: real verifies get recorded -----------------------------------
test_start "stamp records a verify on 'pytest -q'"
reset_care; do_stamp "pytest -q"
assert_ne "$(read_care '.last_verify_iso')" "null" "stamped"

test_start "stamp records on a wrapped verify ('uv run pytest')"
reset_care; do_stamp "uv run pytest tests/"
assert_ne "$(read_care '.last_verify_iso')" "null" "wrapper stamped"

# ---- stamp: false positives must NOT record ------------------------------
test_start "stamp ignores 'pip install pytest'"
reset_care; do_stamp "pip install pytest"
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp ignores a commit message that names a tool (quote-strip)"
reset_care; do_stamp 'git commit -m "ran pytest, all green"'
assert_eq "$(read_care '.last_verify_iso')" "null" "quote-stripped"

test_start "stamp ignores 'cat pytest.ini'"
reset_care; do_stamp "cat pytest.ini"
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp skips a FAILED verify (exit_code 1)"
reset_care
jq -nc '{tool_name:"Bash",tool_input:{command:"pytest"},tool_response:{exit_code:1},hook_event_name:"PostToolUse"}' \
  | bash "$VW" stamp >/dev/null 2>&1
assert_eq "$(read_care '.last_verify_iso')" "null" "failed not stamped"

# ---- commit: whisper when code changed since the last verify -------------
test_start "commit whispers when code changed since verify"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
set_trace "$EDIT"
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "whisper"

test_start "commit is silent on a docs-only change"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
set_trace "$DOC"
assert_eq "$(run_commit 'git commit -m "x"')" "" "docs suppressed"

test_start "commit is silent when the verify postdates the edit"
set_care '{"last_verify_iso":"2026-01-01T12:00:00Z"}'
set_trace "$EDIT"
assert_eq "$(run_commit 'git commit -m "x"')" "" "verify covers edit"

test_start "commit cooldown silences a repeat commit (one per edit-batch)"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
set_trace "$EDIT"
run_commit 'git commit -m "x"' >/dev/null
assert_eq "$(run_commit 'git commit -m "again"')" "" "cooldown"

test_start "commit-mode is silent on a non-commit ('git status')"
reset_care; set_trace "$EDIT"
assert_eq "$(run_commit 'git status')" "" "not a commit"

# ---- never blocks --------------------------------------------------------
test_start "stamp exits 0 on empty stdin"
printf '' | bash "$VW" stamp >/dev/null 2>&1
assert_exit "$?" "0" "empty stamp"

test_start "commit exits 0 on empty stdin"
printf '' | bash "$VW" commit >/dev/null 2>&1
assert_exit "$?" "0" "empty commit"

print_summary
teardown_test_env
exit $FAILED
