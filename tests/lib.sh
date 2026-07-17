#!/usr/bin/env bash
# Test scaffold for maude hook scripts. Sourced by every tests/test-*.sh.
#
# Each test file is expected to:
#   1. source this lib
#   2. call setup_test_env (creates isolated $TEST_TMP, exports CLAUDE_PROJECT_DIR)
#   3. run scenarios with assert_* helpers
#   4. call teardown_test_env
#   5. exit with $FAIL count
#
# State isolation: every test sets CLAUDE_PROJECT_DIR=$TEST_TMP and the hooks
# use maude_project_dir which prefers that env var, so all .maude/plugin/
# state lands inside $TEST_TMP and cleans up at teardown. No state leaks
# between tests.

set +e

# Find the maude project root from this lib's path: tests/lib.sh → ..
MAUDE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$MAUDE_ROOT/hooks/scripts"
# shellcheck disable=SC2034  # used by sourcing test files (e.g. test-verify.sh)
SCRIPTS_DIR="$MAUDE_ROOT/scripts"

PASSED=0
FAILED=0
TEST_NAME=""

setup_test_env() {
  TEST_TMP="$(mktemp -d)"
  # Hermetic: drop any ambient MAUDE_* runtime toggle inherited from the dev
  # shell (e.g. MAUDE_RUN_GOVERNOR=off, MAUDE_RETENTION_DAYS=1) so it can't leak
  # in and flip a default-behavior test. Tests that exercise a toggle set it
  # explicitly AFTER this. ${!MAUDE_@} future-proofs against toggles not yet
  # invented — an explicit unset-list rots.
  for _v in "${!MAUDE_@}"; do unset "$_v"; done
  export CLAUDE_PROJECT_DIR="$TEST_TMP"
  export MAUDE_GATE_CONFIG="$TEST_TMP/gate-config.json"
  mkdir -p "$TEST_TMP/.maude/plugin/trace"
  printf '*\n' > "$TEST_TMP/.maude/plugin/.gitignore"
}

teardown_test_env() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
  unset CLAUDE_PROJECT_DIR TEST_TMP MAUDE_GATE_CONFIG
}

test_start() {
  TEST_NAME="$1"
}

_pass() {
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "$TEST_NAME"
}

_fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s — %s\n' "$TEST_NAME" "$1" >&2
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-eq}"
  if [ "$actual" = "$expected" ]; then
    _pass
  else
    _fail "$label: expected=$(printf '%q' "$expected") got=$(printf '%q' "$actual")"
  fi
}

assert_ne() {
  local actual="$1" forbidden="$2" label="${3:-ne}"
  if [ "$actual" != "$forbidden" ]; then
    _pass
  else
    _fail "$label: value should not equal $(printf '%q' "$forbidden")"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-contains}"
  case "$haystack" in
    *"$needle"*) _pass ;;
    *) _fail "$label: '$needle' not in '$haystack'" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-not_contains}"
  case "$haystack" in
    *"$needle"*) _fail "$label: '$needle' unexpectedly found in '$haystack'" ;;
    *) _pass ;;
  esac
}

assert_exit() {
  local actual="$1" expected="$2" label="${3:-exit}"
  if [ "$actual" = "$expected" ]; then
    _pass
  else
    _fail "$label: expected exit=$expected got=$actual"
  fi
}

assert_file_exists() {
  local path="$1" label="${2:-file_exists}"
  if [ -f "$path" ]; then
    _pass
  else
    _fail "$label: $path does not exist"
  fi
}

assert_file_absent() {
  local path="$1" label="${2:-file_absent}"
  if [ ! -e "$path" ]; then
    _pass
  else
    _fail "$label: $path exists but should not"
  fi
}

# Build a Bash tool input JSON envelope.
# Usage: make_bash_tool_input "<command>"
make_bash_tool_input() {
  local cmd="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg cmd "$cmd" '{tool_name:"Bash", tool_input:{command:$cmd}, hook_event_name:"PreToolUse"}'
  else
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"hook_event_name":"PreToolUse"}\n' \
      "$(printf '%s' "$cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  fi
}

# Build an Edit tool input JSON envelope.
make_edit_tool_input() {
  local file_path="$1"
  jq -nc --arg fp "$file_path" \
    '{tool_name:"Edit", tool_input:{file_path:$fp}, hook_event_name:"PreToolUse"}'
}

# Build a Read tool input JSON envelope.
make_read_tool_input() {
  local file_path="$1"
  jq -nc --arg fp "$file_path" \
    '{tool_name:"Read", tool_input:{file_path:$fp}, hook_event_name:"PreToolUse"}'
}

# Build an MCP tool input JSON envelope.
# Usage: make_mcp_tool_input "<tool_name>" '<tool_input json object>'
make_mcp_tool_input() {
  local tool="$1"
  local args="$2"
  [ -z "$args" ] && args='{}'
  jq -nc --arg t "$tool" --argjson a "$args" \
    '{tool_name:$t, tool_input:$a, hook_event_name:"PreToolUse"}'
}

trace_path() {
  # UTC date — matches maude_trace_file()'s single-clock filename so tests stay
  # correct on non-UTC boxes too.
  printf '%s/.maude/plugin/trace/today-%s.jsonl' "$TEST_TMP" "$(date -u +%Y-%m-%d)"
}

care_path() {
  printf '%s/.maude/plugin/care.json' "$TEST_TMP"
}

# The dedicated RED-clear token file (v0.10.1): red clears live here, separate
# from care.json, so the harness can lock it and the gate can block Bash writes.
redclear_path() {
  printf '%s/.maude/plugin/care-redclear.json' "$TEST_TMP"
}

# Read a value from care.json by jq path (without leading dot).
# Usage: read_care '.gate_cleared["git-push"].until'
read_care() {
  local query="$1"
  [ -f "$(care_path)" ] || { printf 'null'; return; }
  command -v jq >/dev/null 2>&1 || { printf 'null'; return; }
  jq -r "$query" "$(care_path)" 2>/dev/null
}

# Count lines in trace JSONL matching a jq filter.
# Usage: count_trace_lines '.kind == "gate" and .payload | test("blocked")'
count_trace_lines() {
  local filter="$1"
  local trace
  trace="$(trace_path)"
  [ -f "$trace" ] || { printf '0'; return; }
  command -v jq >/dev/null 2>&1 || { printf '0'; return; }
  jq -c "select($filter)" "$trace" 2>/dev/null | wc -l | tr -d ' '
}

# Print a one-line summary at end of test.
print_summary() {
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
}

# Source common helpers under test (the SUT for unit-style tests).
source_common() {
  . "$HOOKS_DIR/_maude-common.sh"
}

# Portable mtime setters — GNU `touch -d` date-strings don't exist on
# macOS/BSD, so tests set mtimes via python3 stdlib os.utime instead
# (python3 is already a plugin dependency: the vault floor).
# Argument order mirrors `touch -d WHEN FILE...`: timestamp first.

# touch_ago <seconds-ago> <file>... — mtime = now - N; creates missing files.
touch_ago() {
  local ago="$1"; shift
  local f
  for f in "$@"; do [ -e "$f" ] || : > "$f"; done
  python3 - "$ago" "$@" <<'PY'
import os, sys, time
t = time.time() - float(sys.argv[1])
for p in sys.argv[2:]:
    os.utime(p, (t, t))
PY
}

# touch_at <epoch|ISO8601[Z]> <file>... — absolute mtime; creates missing files.
touch_at() {
  local when="$1"; shift
  local f
  for f in "$@"; do [ -e "$f" ] || : > "$f"; done
  python3 - "$when" "$@" <<'PY'
import os, sys, datetime
w = sys.argv[1]
try:
    t = float(w)
except ValueError:
    t = datetime.datetime.fromisoformat(w.replace('Z', '+00:00')).timestamp()
for p in sys.argv[2:]:
    os.utime(p, (t, t))
PY
}

# Build a PATH directory containing every common binary EXCEPT jq, so a test can
# exercise the jq-absent degradation path that the plugin promises to handle.
# Prints the dir. Usage: NOJQ="$(make_nojq_bin)"; PATH="$NOJQ" bash "$SCRIPT"
# (jq is deliberately omitted so `command -v jq` fails under this PATH.)
make_nojq_bin() {
  local d b src
  d="$(mktemp -d)"
  for b in bash sh env cat date grep sed awk tr head tail wc find \
           mktemp mv rm cp mkdir rmdir dirname basename cut ls touch \
           sort uniq readlink stat sleep chmod printf; do
    src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$d/$b" 2>/dev/null
  done
  printf '%s' "$d"
}

# Like make_nojq_bin but ALSO omits grep — exercises the deepest degradation path
# where the infra-gate cannot identify the tool name at all. Prints the dir.
make_nojq_nogrep_bin() {
  local d b src
  d="$(mktemp -d)"
  for b in bash sh env cat date sed awk tr head tail wc find \
           mktemp mv rm cp mkdir rmdir dirname basename cut ls touch \
           sort uniq readlink stat sleep chmod printf; do
    src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$d/$b" 2>/dev/null
  done
  printf '%s' "$d"
}
