#!/usr/bin/env bash
# Tests for hooks/scripts/maude-verify-watch.sh — the assert-without-verify tripwire.
#   stamp  (PostToolUse·Bash) records an ISO ts when a verify run EXITS 0.
#   commit (PreToolUse·Bash) whispers once when CODE changed since the last verify.
# Always exits 0; whisper goes to stderr.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

VW="$HOOKS_DIR/maude-verify-watch.sh"

reset_care()  { printf '{}\n' > "$(care_path)"; }
set_care()    { printf '%s\n' "$1" > "$(care_path)"; }
set_trace()   { : > "$(trace_path)"; for l in "$@"; do printf '%s\n' "$l" >> "$(trace_path)"; done; }
# stamp with an explicit exit code (a real PostToolUse·Bash tool_response shape)
do_stamp_x()  { jq -nc --arg c "$1" --argjson ec "$2" \
                  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{exit_code:$ec},hook_event_name:"PostToolUse"}' \
                  | bash "$VW" stamp >/dev/null 2>&1; }
# stamp with NO exit code surfaced (an unproven run)
do_stamp()    { make_bash_tool_input "$1" | bash "$VW" stamp >/dev/null 2>&1; }
run_commit()  { make_bash_tool_input "$1" | bash "$VW" commit 2>&1 >/dev/null; }

EDIT='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/foo.py"}'
EDIT2='{"ts":"2026-01-01T11:30:00Z","kind":"tool","tool":"Write","target":"/p/bar.py"}'
DOC='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/README.md"}'

# ---- stamp: a verify that EXITS 0 is recorded ----------------------------
test_start "stamp records a passing 'pytest -q' (exit 0)"
reset_care; do_stamp_x "pytest -q" 0
assert_ne "$(read_care '.last_verify_iso')" "null" "stamped"

test_start "stamp records a passing wrapped verify ('uv run pytest', exit 0)"
reset_care; do_stamp_x "uv run pytest tests/" 0
assert_ne "$(read_care '.last_verify_iso')" "null" "wrapper stamped"

test_start "stamp records a passing SCRIPT verify ('bash run_tests.sh', exit 0)"
reset_care; do_stamp_x "bash run_tests.sh" 0
assert_ne "$(read_care '.last_verify_iso')" "null" "script stamped"

# ---- stamp: failures / unproven runs are NOT recorded --------------------
test_start "stamp skips a FAILED verify (exit 1)"
reset_care; do_stamp_x "pytest" 1
assert_eq "$(read_care '.last_verify_iso')" "null" "failed not stamped"

test_start "stamp skips an UNPROVEN verify (no exit code surfaced)"
reset_care; do_stamp "pytest"
assert_eq "$(read_care '.last_verify_iso')" "null" "unproven not stamped"

# ---- stamp: non-verify / false-positive commands never stamp -------------
test_start "stamp ignores 'pip install pytest' (even on exit 0)"
reset_care; do_stamp_x "pip install pytest" 0
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp ignores a commit message that names a tool (quote-strip)"
reset_care; do_stamp_x 'git commit -m "ran pytest, all green"' 0
assert_eq "$(read_care '.last_verify_iso')" "null" "quote-stripped"

test_start "stamp ignores 'cat pytest.ini'"
reset_care; do_stamp_x "cat pytest.ini" 0
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp ignores a non-test script ('bash latest.sh')"
reset_care; do_stamp_x "bash latest.sh" 0
assert_eq "$(read_care '.last_verify_iso')" "null" "not a test script"

# ---- commit: whisper when code changed since the last verify -------------
test_start "commit whispers when code changed since verify"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'; set_trace "$EDIT"
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "whisper"

test_start "commit whispers on the first commit when never verified"
reset_care; set_trace "$EDIT"
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "first-commit whisper"

test_start "commit whispers on a mixed code+docs batch (a doc can't mask code)"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'; set_trace "$DOC" "$EDIT2"
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "mixed whisper"

# ---- commit: suppressed / silent cases -----------------------------------
test_start "commit is silent on a docs-only change"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'; set_trace "$DOC"
assert_eq "$(run_commit 'git commit -m "x"')" "" "docs suppressed"

test_start "commit is silent when the verify postdates the edit"
set_care '{"last_verify_iso":"2026-01-01T12:00:00Z"}'; set_trace "$EDIT"
assert_eq "$(run_commit 'git commit -m "x"')" "" "verify covers edit"

test_start "commit-mode is silent on a non-commit ('git status')"
reset_care; set_trace "$EDIT"
assert_eq "$(run_commit 'git status')" "" "not a commit"

# ---- commit: cooldown is one-per-batch AND re-arms on a new edit ----------
test_start "commit cooldown silences a repeat commit (same batch)"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'; set_trace "$EDIT"
run_commit 'git commit -m "x"' >/dev/null
assert_eq "$(run_commit 'git commit -m "again"')" "" "cooldown"

test_start "commit whispers AGAIN after a new edit (cooldown re-arms)"
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'; set_trace "$EDIT"
run_commit 'git commit -m "x"' >/dev/null     # warns, sets warned_for
set_trace "$EDIT" "$EDIT2"                     # a newer edit lands
assert_contains "$(run_commit 'git commit -m "y"')" "asserting it" "re-whisper on new edit"

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
