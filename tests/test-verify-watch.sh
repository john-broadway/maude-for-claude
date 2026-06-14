#!/usr/bin/env bash
# Tests for hooks/scripts/maude-verify-watch.sh — the assert-without-verify tripwire.
#   stamp  (PostToolUse·Bash) records an ISO ts when a verify RAN TO COMPLETION
#          without a visible failure (belt-and-suspenders — the Bash tool_response
#          surfaces no exit code, so completion + clean output is the pass signal).
#   commit (PreToolUse·Bash) whispers once when CODE changed since the last verify.
# Always exits 0; whisper goes to stderr.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

VW="$HOOKS_DIR/maude-verify-watch.sh"

reset_care()  { printf '{}\n' > "$(care_path)"; }
set_care()    { printf '%s\n' "$1" > "$(care_path)"; }

trace_dir()    { printf '%s/.maude/plugin/trace' "$TEST_TMP"; }
clear_traces() { rm -f "$(trace_dir)"/today-*.jsonl 2>/dev/null; }
# Write a dated trace file (today-<DATE>.jsonl) with the given JSONL lines, so a
# test can place edits in specific files and exercise the two-most-recent read.
write_trace()  { local d="$1"; shift; local f; f="$(trace_dir)/today-$d.jsonl"; : > "$f"; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done; }
# Default trace setter: clean slate, then write to TODAY's real file.
set_trace()    { clear_traces; : > "$(trace_path)"; for l in "$@"; do printf '%s\n' "$l" >> "$(trace_path)"; done; }

# A real PostToolUse·Bash tool_response carries {stdout,stderr,interrupted} — there is
# NO exit_code field for Bash. do_stamp <cmd> [stdout] [stderr] [interrupted(true|false)]
do_stamp()    { jq -nc --arg c "$1" --arg o "${2:-}" --arg e "${3:-}" --argjson i "${4:-false}" \
                  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:$e,interrupted:$i,isImage:false,noOutputExpected:false},hook_event_name:"PostToolUse"}' \
                  | bash "$VW" stamp >/dev/null 2>&1; }
run_commit()  { { make_bash_tool_input "$1" | bash "$VW" commit >/dev/null; } 2>&1; }

EDIT='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/foo.py"}'
EDIT2='{"ts":"2026-01-01T11:30:00Z","kind":"tool","tool":"Write","target":"/p/bar.py"}'
DOC='{"ts":"2026-01-01T11:00:00Z","kind":"tool","tool":"Edit","target":"/p/README.md"}'

# ---- stamp: a verify that ran to completion (clean output) is recorded ----
test_start "stamp records a completed 'pytest -q' (clean output)"
reset_care; do_stamp "pytest -q" "5 passed in 0.10s"
assert_ne "$(read_care '.last_verify_iso')" "null" "stamped"

test_start "stamp records a wrapped verify ('uv run pytest')"
reset_care; do_stamp "uv run pytest tests/" "12 passed"
assert_ne "$(read_care '.last_verify_iso')" "null" "wrapper stamped"

test_start "stamp records a SCRIPT verify ('bash run_tests.sh')"
reset_care; do_stamp "bash run_tests.sh" "OK"
assert_ne "$(read_care '.last_verify_iso')" "null" "script stamped"

# ---- stamp: broadened runners across ecosystems (the v0.5.0 headline) ----
test_start "stamp records 'npm test'"
reset_care; do_stamp "npm test" "Tests: 5 passed, 5 total"
assert_ne "$(read_care '.last_verify_iso')" "null" "npm stamped"

test_start "stamp records 'go test ./...'"
reset_care; do_stamp "go test ./..." "ok  example/pkg  0.2s"
assert_ne "$(read_care '.last_verify_iso')" "null" "go stamped"

test_start "stamp records 'cargo test'"
reset_care; do_stamp "cargo test" "test result: ok. 8 passed; 0 failed"
assert_ne "$(read_care '.last_verify_iso')" "null" "cargo stamped"

test_start "stamp records 'mvn verify'"
reset_care; do_stamp "mvn verify" "BUILD SUCCESS"
assert_ne "$(read_care '.last_verify_iso')" "null" "mvn stamped"

test_start "stamp records 'dotnet test'"
reset_care; do_stamp "dotnet test" "Passed!  - Failed: 0, Passed: 10"
assert_ne "$(read_care '.last_verify_iso')" "null" "dotnet stamped"

test_start "stamp records 'mix test'"
reset_care; do_stamp "mix test" "5 tests, 0 failures"
assert_ne "$(read_care '.last_verify_iso')" "null" "mix stamped"

test_start "stamp records 'bundle exec rspec' (bundler wrapper)"
reset_care; do_stamp "bundle exec rspec" "5 examples, 0 failures in 0.1s"
assert_ne "$(read_care '.last_verify_iso')" "null" "bundle exec stamped"

# ---- stamp: belt — an interrupted run is NOT recorded --------------------
test_start "stamp skips an INTERRUPTED verify (cancelled / timed out)"
reset_care; do_stamp "pytest" "" "" true
assert_eq "$(read_care '.last_verify_iso')" "null" "interrupted not stamped"

# ---- stamp: suspenders — output reporting failure is NOT recorded --------
test_start "stamp skips a verify whose output reports failures ('1 failed')"
reset_care; do_stamp "pytest -q" "1 failed, 4 passed in 0.3s"
assert_eq "$(read_care '.last_verify_iso')" "null" "failing output not stamped"

test_start "stamp skips a verify that crashed (Traceback on stderr)"
reset_care; do_stamp "pytest" "" "Traceback (most recent call last):
  File \"x.py\", line 1"
assert_eq "$(read_care '.last_verify_iso')" "null" "traceback not stamped"

test_start "stamp skips a failed 'go test' (--- FAIL on stdout)"
reset_care; do_stamp "go test ./..." "--- FAIL: TestThing (0.00s)
FAIL"
assert_eq "$(read_care '.last_verify_iso')" "null" "go fail not stamped"

test_start "stamp skips a failed 'dotnet test' (count-after: 'Failed: 3')"
reset_care; do_stamp "dotnet test" "Failed!  - Failed:     3, Passed:     7, Skipped:     0"
assert_eq "$(read_care '.last_verify_iso')" "null" "dotnet fail not stamped"

test_start "stamp skips a failed 'mocha' run ('1 failing')"
reset_care; do_stamp "npx mocha" "4 passing
1 failing"
assert_eq "$(read_care '.last_verify_iso')" "null" "mocha fail not stamped"

test_start "stamp skips a failed 'bundle exec rspec' ('1 failure')"
reset_care; do_stamp "bundle exec rspec" "5 examples, 1 failure"
assert_eq "$(read_care '.last_verify_iso')" "null" "rspec fail not stamped"

# ---- stamp: non-verify / false-positive commands never stamp -------------
test_start "stamp ignores 'pip install pytest'"
reset_care; do_stamp "pip install pytest" "Successfully installed pytest-8.0"
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp ignores a commit message that names a tool (quote-strip)"
reset_care; do_stamp 'git commit -m "ran pytest, all green"' ""
assert_eq "$(read_care '.last_verify_iso')" "null" "quote-stripped"

test_start "stamp ignores 'cat pytest.ini'"
reset_care; do_stamp "cat pytest.ini" "[pytest]"
assert_eq "$(read_care '.last_verify_iso')" "null" "no false stamp"

test_start "stamp ignores a non-test script ('bash latest.sh')"
reset_care; do_stamp "bash latest.sh" ""
assert_eq "$(read_care '.last_verify_iso')" "null" "not a test script"

# ---- stamp: command-position anchoring (a NAME is not a RUN) -------------
test_start "stamp ignores 'which pytest' (a lookup, not a run)"
reset_care; do_stamp "which pytest" "/usr/bin/pytest"
assert_eq "$(read_care '.last_verify_iso')" "null" "which not stamped"

test_start "stamp ignores an unquoted mention ('echo pytest')"
reset_care; do_stamp "echo pytest" "pytest"
assert_eq "$(read_care '.last_verify_iso')" "null" "echo not stamped"

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

# ---- commit: a malformed trace line must not blind the tripwire ----------
test_start "commit still whispers when an older trace line is malformed"
clear_traces
write_trace "2026-01-01" 'this is not json {{{' "$EDIT"
write_trace "2026-01-02"                        # today: empty
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "malformed line skipped"

# ---- commit: the two-most-recent-file read survives UTC midnight ---------
test_start "commit reads YESTERDAY's trace file (edit made before UTC midnight)"
clear_traces
write_trace "2026-01-01" "$EDIT"                # "yesterday": holds the edit
write_trace "2026-01-02"                        # "today": empty
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
assert_contains "$(run_commit 'git commit -m "x"')" "asserting it" "two-file read"

test_start "commit ignores an edit older than the two-most-recent files"
clear_traces
write_trace "2026-01-01" "$EDIT"                # oldest — outside the two-file window
write_trace "2026-01-02"                        # empty
write_trace "2026-01-03"                        # empty (today)
set_care '{"last_verify_iso":"2026-01-01T10:00:00Z"}'
assert_eq "$(run_commit 'git commit -m "x"')" "" "tail -2 window boundary"

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
