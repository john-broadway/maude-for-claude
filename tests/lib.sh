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
#
# ENV isolation is the other half of that promise, and it was missing. Earned
# 2026-08-17: an ambient SHIP_SOURCE_REF — exported to build a release — leaked
# into test-ship.sh's subprocesses and turned 18 passing tests into 2 passed /
# 16 failed, with nothing wrong in the code. A gate whose verdict depends on the
# caller's shell is not a gate; it also means a seam left on from an earlier
# command silently changes what the suite proves. (MAUDE_RUN_GOVERNOR was in
# fact set in the shell that found this.)
#
# Derived from the environment, never a typed list: there are 50-odd seams and a
# hand-written list is the thing that keeps falling behind. Tests that WANT a seam
# still set it per-invocation (FOO=bar cmd), which this cannot disturb.

set +e

# The one exception, and it is a safety one: MAUDE_EYE_BLINK is the eye's
# recursion guard — hooks check it to stay inert inside a blink subprocess.
# Clearing it could let a test run spawn the very recursion it prevents.
for _seam in $(env | sed -n 's/^\(\(MAUDE\|SHIP\)_[A-Za-z0-9_]*\)=.*/\1/p'); do
    [ "$_seam" = "MAUDE_EYE_BLINK" ] && continue
    unset "$_seam"
done
unset _seam

# Find the maude project root from this lib's path: tests/lib.sh → ..
MAUDE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$MAUDE_ROOT/hooks/scripts"
# shellcheck disable=SC2034  # used by sourcing test files (e.g. test-verify.sh)
SCRIPTS_DIR="$MAUDE_ROOT/scripts"

# Every temp dir this file makes lands under one root, swept when the file exits. Earned
# 2026-09-05: 7,471 leaked /tmp/tmp.* dirs on the dev box, from six fixtures one file never
# removed and the shim bins below, taken by fourteen files and swept by three; /tmp is a 4G
# tmpfs there and hit 100% twice, faking a scatter of unrelated failures. GNU mktemp
# honours TMPDIR with no template; macOS mktemp does not (it uses the per-user Darwin temp
# dir, so the leak sweep and the root refusal below never fired on the GitHub macOS runner,
# 2026-09-13), so every mktemp in THIS FILE, in tests/run.sh and in scripts/install-smoke.sh
# names a template under "${TMPDIR:-/tmp}".
#
# ⚠ NOT yet true of the suite at large, and an earlier draft of this sentence claimed it was.
# Counted 2026-09-14: 35 untemplated `$(mktemp)` / `$(mktemp -d)` calls across 12 test files
# (test-verify.sh 18, test-session-start.sh 6, test-_maude-common.sh 2, and 9 more with one
# each). Counted again 2026-09-14 because the first draft of THIS correction was itself wrong:
# it said "only test-portability.sh's three are ever rm -rf'd", when 24 of the 35 do carry an
# explicit rm -rf and test-portability contributes exactly ONE of them, which its own "9 more
# with one each" already contradicted. The real residual is 11 never removed: TMP in
# test-care.sh and test-probe-tier1.sh, WORK in test-eye-blink.sh and test-vault-hooks.sh, and
# seven in test-verify.sh. By the macOS behaviour stated two lines up, all 35 land outside
# TEST_TMPROOT (so the EXIT trap below does not sweep them) and outside SUITE_TMP (so run.sh's
# leak refusal cannot see them), removed or not. Five are PATH-injection shim dirs: BSD_BIN,
# NODATE (x2), STUB_DIR, NOFLOCK_SHIM. None of the 35 checks whether its mktemp SUCCEEDED, which
# is the hazard _mk_shim_dir below closes for the three it owns; four of those five do rm -rf
# their dir, so "unguarded" here means unguarded against mktemp FAILURE, not unswept. That sweep
# is owed and is deliberately NOT claimed done here; a comment that overstates its own reach is
# the defect this paragraph exists to record, twice now. The variable is readonly, so nothing a test later unsets
# can take the path from the trap; a first version expanded the path into the trap string
# instead, and one apostrophe in TMPDIR broke that string at exit. A file that sets its own
# EXIT trap replaces this one and leaks the root, so no test file does; tests/run.sh refuses
# green for any file that leaves something behind, which is what keeps this fixed. A mktemp
# that fails (a stale ambient TMPDIR) used to leave TMPDIR empty and every fixture back in
# /tmp with nothing said; a file without an isolated root does not run.
# "${TMPDIR%/}": macOS exports TMPDIR with a trailing slash, and a root built as "$TMPDIR/x"
# carries "//"; the gate canonicalises a command's repeated slashes before matching, so a
# protected root configured from such a path matched nothing (22 sole-copy pins, PR #69).
# One resolver for every temp base in this file, so setup_test_env and _mk_shim_dir below
# cannot drift from it again (they did: both read a bare ${TMPDIR%/} while the comment above
# claimed every mktemp named a template under "${TMPDIR:-/tmp}"). Referenced by NAME, not by
# line number: the first draft of this note cited "line 72", which its own insertion moved.
_tmp_base_of() { local b="${1:-}"; b="${b:-/tmp}"; b="${b%/}"; [ -n "$b" ] || b=/; printf '%s' "$b"; }
_tmp_base="$(_tmp_base_of "${TMPDIR:-}")"
TEST_TMPROOT="$(mktemp -d "${_tmp_base}/maude-tests.XXXXXX")" || { printf 'tests/lib.sh: mktemp -d failed under TMPDIR=%s; a file without an isolated root does not run\n' "${TMPDIR:-<unset>}" >&2; exit 2; }
readonly TEST_TMPROOT
export TMPDIR="$TEST_TMPROOT"
trap 'rm -rf "$TEST_TMPROOT"' EXIT

PASSED=0
FAILED=0
TEST_NAME=""

setup_test_env() {
  TEST_TMP="$(mktemp -d "$(_tmp_base_of "${TMPDIR:-}")/maude-test.XXXXXX")" || {
    printf 'tests/lib.sh: mktemp -d failed under TMPDIR=%s; a test without its own dir does not run\n' "${TMPDIR:-<unset>}" >&2
    exit 2
  }
  # Hermetic: drop any ambient MAUDE_* runtime toggle inherited from the dev
  # shell (e.g. MAUDE_RUN_GOVERNOR=off, MAUDE_RETENTION_DAYS=1) so it can't leak
  # in and flip a default-behavior test. Tests that exercise a toggle set it
  # explicitly AFTER this. ${!MAUDE_@} future-proofs against toggles not yet
  # invented — an explicit unset-list rots.
  for _v in "${!MAUDE_@}"; do unset "$_v"; done
  # Session-label hermeticity: the suite may run inside a tmux fleet session
  # AND under a live harness that exports its session id — maude_session_label
  # would resolve to THAT session's identity, the exact ambient-state leak the
  # label exists to stop. Tests that exercise labeling set MAUDE_SESSION_LABEL
  # (or pass a session_id) explicitly.
  unset TMUX CLAUDE_CODE_SESSION_ID
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

# file_digest <file> — content hash for byte-identity assertions. GNU md5sum
# doesn't exist on macOS (BSD ships `md5`), so hash via python3 stdlib. A
# missing/unreadable file prints nothing and returns 1 — never a hash both
# sides could vacuously agree on.
# Inode and mode, GNU stat first and BSD stat second; the tests that pin an atomic rename
# and a carried mode compared empty strings on macOS and read "rewritten in place".
file_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
file_mode()  { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

file_digest() {
  python3 -c 'import hashlib, sys
try:
    print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
except OSError:
    sys.exit(1)' "$1"
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

# HARDENING, not the cause of the 2026-09-13 macOS red. An earlier draft of this comment said
# an empty PATH "falls back to a default PATH and runs the real binary", so the control would
# go quietly GREEN. That is false, and measured: bash falls back to a compiled default only
# when PATH is UNSET; PATH set-but-EMPTY searches the current directory and an absent binary is
# a hard 127. Planting this failure gives `expected exit=2 got=127`, never the `got=0` the
# macOS red actually showed. That red was a race in the eye-probe poll (see
# tests/test-suite-runner.sh); this guard is a separate silent-control hazard found beside it.
#
# What an unchecked mktemp really costs: `d` is empty, so the builder loop below runs
# `ln -s "$src" "/bash"`, `"/pgrep"` … writing symlinks into / as root on this sole-copy box,
# and the caller's 127 then reads like a missing interpreter rather than a missing fixture.
# TEST_TMPROOT above already refused loudly on this exact failure; these three did not. Resolve
# the base through _tmp_base_of rather than a bare ${TMPDIR%/}, and refuse with the reason.
# Every caller takes this through a command substitution (`X="$(make_no_binary_bin sleep)"`),
# so an `exit` here kills only the subshell and the caller carries on with an empty string.
# The first draft of this guard did exactly that: it printed a refusal AND still handed back
# "" with status 0, which is the very defect it was written to close. So on failure it prints
# the reason and returns a POISON path, which beats "" for two reasons: the failure names a
# fixture instead of looking like a missing interpreter, and nothing is written into /.
# KNOWN LIMIT: this is loud for `PATH="$D" cmd` (the replace form). Callers that PREPEND
# (`PATH="$D:$PATH"`) still find the real binary, so for those the poison is not a backstop and
# the stderr line above is the only signal. Nine prepend-form call sites take a dir from _mk_shim_dir (six in test-_maude-common.sh,
# three in test-gate.sh). The suite has 19 prepend sites in all; the other 10 use bare-mktemp
# dirs, for which the poison is equally not a backstop.
_MK_SHIM_POISON='/nonexistent/maude-shim-dir-FAILED'
_mk_shim_dir() {
  local base d
  base="$(_tmp_base_of "${TMPDIR:-}")"
  if ! d="$(mktemp -d "${base}/maude-bin.XXXXXX" 2>/dev/null)" || [ -z "$d" ] || [ ! -d "$d" ]; then
    printf 'tests/lib.sh: mktemp -d failed under TMPDIR=%s (got "%s"); a shim bin that is not created silently disables the control that uses it, so returning %s\n' \
      "${TMPDIR:-<unset>}" "$d" "$_MK_SHIM_POISON" >&2
    printf '%s' "$_MK_SHIM_POISON"
    return 2
  fi
  printf '%s' "$d"
}
# (jq is deliberately omitted so `command -v jq` fails under this PATH.)
make_nojq_bin() {
  local d b src
  d="$(_mk_shim_dir)"
  for b in bash sh env cat date grep sed awk tr head tail wc find \
           mktemp mv rm cp mkdir rmdir dirname basename cut ls touch \
           sort uniq readlink stat sleep chmod printf; do
    src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$d/$b" 2>/dev/null
  done
  printf '%s' "$d"
}

# Build a PATH dir carrying the common toolset EXCEPT the named binaries —
# for exercising absent-tool degradation paths (macOS ships no flock(1),
# timeout(1), or md5sum). Unlike make_nojq_bin this INCLUDES jq and python3.
# Usage: D="$(make_no_binary_bin flock)"; PATH="$D" bash "$SCRIPT"
make_no_binary_bin() {
  local d b src
  d="$(_mk_shim_dir)"
  for b in bash sh env cat date grep sed awk tr head tail wc find xargs \
           mktemp mv rm cp mkdir rmdir dirname basename cut ls touch \
           sort uniq readlink stat sleep chmod printf jq python3 nohup \
           tee od uname flock timeout pgrep cksum shasum sum; do
    case " $* " in (*" $b "*) continue ;; esac
    src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$d/$b" 2>/dev/null
  done
  printf '%s' "$d"
}

# Like make_nojq_bin but ALSO omits grep — exercises the deepest degradation path
# where the infra-gate cannot identify the tool name at all. Prints the dir.
make_nojq_nogrep_bin() {
  local d b src
  d="$(_mk_shim_dir)"
  for b in bash sh env cat date sed awk tr head tail wc find \
           mktemp mv rm cp mkdir rmdir dirname basename cut ls touch \
           sort uniq readlink stat sleep chmod printf; do
    src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$d/$b" 2>/dev/null
  done
  printf '%s' "$d"
}
