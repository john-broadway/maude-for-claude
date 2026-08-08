#!/usr/bin/env bash
# Tests for maude_project_dir()'s INFERENCE path — the process-tree walk and the
# filesystem walk-up.
#
# WHY THIS FILE EXISTS
# test-_maude-common.sh could only assert that the resolver "returns SOMETHING
# reasonable: a non-empty existing directory", because from inside a live Claude
# Code session the proc walk always short-circuits on the real `claude` process.
# That test cannot fail for any wrong answer, so the resolver's two inference
# strategies were effectively untested — and both were broken:
#
#   1. The PPID was read as `awk '{print $4}' /proc/<pid>/stat`. Field 2 of that
#      file is `comm` wrapped in parens and comm MAY CONTAIN SPACES. A `tmux:
#      server` ancestor splits into two whitespace fields and shifts every later
#      field by one, so $4 yields the process STATE LETTER ("S"), not the parent
#      pid. Measured on the live box 2026-07-31:
#          $ cat /proc/943593/stat  ->  943593 (tmux: server) S 1 ...
#          $ awk '{print $4}' ...   ->  S
#          $ grep ^PPid /proc/943593/status -> PPid: 1
#      The walk then dies at that ancestor and falls through to $(pwd).
#      A foreground session survives only because `claude` is the IMMEDIATE
#      parent and the walk returns on iteration 1. Add one process layer — which
#      is what a backgrounded call does — and it breaks.
#
#   2. Nothing stopped inference landing on $HOME. Combined with (1) that is the
#      "$HOME phantom": the walk dies, resolution falls to /root, a caller mkdirs
#      ~/.maude/plugin, and from then on the filesystem walk-up STOPS at that
#      phantom for every path outside the real workspace. It broke the mission
#      clear, the undo list and the conscience clear on 2026-07-30.
#
# The seams (MAUDE_PROC_ROOT / MAUDE_PROC_START_PID) exist so these paths can be
# driven against a fixture process tree. Both are unset in normal use.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

# Build one fake /proc/<pid> entry.
# Usage: mkproc <procroot> <pid> <comm> <ppid> <cwd>
mkproc() {
  local root="$1" pid="$2" comm="$3" ppid="$4" cwd="$5" d
  d="$root/$pid"
  mkdir -p "$d"
  printf '%s\n' "$comm" > "$d/comm"
  # Mirror the real layout: pid, (comm), state, ppid, then the rest.
  printf '%s (%s) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 0 0\n' "$pid" "$comm" "$ppid" > "$d/stat"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPPid:\t%s\n' "$comm" "$ppid" > "$d/status"
  ln -sfn "$cwd" "$d/cwd"
}

PROC="$TEST_TMP/proc"
PROJ="$TEST_TMP/proj"
mkdir -p "$PROJ"

# ── 1. THE REGRESSION: an ancestor whose comm contains a space ────────
# bash(100) -> tmux: server(200) -> claude(300, cwd=$PROJ)
# The walk must reach pid 300. With the $4-of-stat parse it dies at 200.
test_start "proc walk traverses an ancestor whose comm contains a space"
mkproc "$PROC" 100 "bash"         200 "$TEST_TMP"
mkproc "$PROC" 200 "tmux: server" 300 "$TEST_TMP"
mkproc "$PROC" 300 "claude"         1 "$PROJ"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC" MAUDE_PROC_START_PID=100
  cd "$TEST_TMP" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$PROJ" "walked past the space-in-comm ancestor"

# ── 2. The happy path must keep working (claude as immediate parent) ──
test_start "proc walk finds an immediate claude parent"
PROC2="$TEST_TMP/proc2"
mkproc "$PROC2" 100 "claude" 1 "$PROJ"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC2" MAUDE_PROC_START_PID=100
  cd "$TEST_TMP" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$PROJ" "immediate claude parent"

# ── 3. Inference must never land on $HOME ─────────────────────────────
# A claude process whose cwd IS $HOME must not make $HOME the project root:
# that is what mints the phantom closet that shadows everything afterwards.
test_start "proc walk refuses a claude cwd equal to \$HOME"
FAKE_HOME="$TEST_TMP/home"
mkdir -p "$FAKE_HOME/work"
PROC3="$TEST_TMP/proc3"
mkproc "$PROC3" 100 "claude" 1 "$FAKE_HOME"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC3" MAUDE_PROC_START_PID=100 HOME="$FAKE_HOME"
  cd "$FAKE_HOME/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$FAKE_HOME" "inferred root is not \$HOME"

# ── 4. The filesystem walk-up must not stop at a closet in $HOME ──────
# This is the SHADOWING half: once a phantom exists at $HOME, every walk from a
# deeper path used to stop there.
test_start "filesystem walk-up skips a phantom closet at \$HOME"
mkdir -p "$FAKE_HOME/.maude/plugin" "$FAKE_HOME/work"
EMPTY_PROC="$TEST_TMP/proc-empty"
mkdir -p "$EMPTY_PROC"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$FAKE_HOME"
  cd "$FAKE_HOME/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$FAKE_HOME" "walk-up did not stop at the \$HOME phantom"

# ── 5. A genuine closet BELOW $HOME is still found ────────────────────
# The guard must reject only $HOME ITSELF, not everything under it — otherwise
# it would break every ordinary workspace, which all live under $HOME.
test_start "filesystem walk-up still finds a real closet below \$HOME"
mkdir -p "$FAKE_HOME/ws/.maude/plugin" "$FAKE_HOME/ws/deep/deeper"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$FAKE_HOME"
  cd "$FAKE_HOME/ws/deep/deeper" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$FAKE_HOME/ws" "real closet below \$HOME still wins"

# ── 6. An EXPLICIT declaration of $HOME is still honored ──────────────
# Explicit beats inferred. Hooks always carry CLAUDE_PROJECT_DIR, so a genuinely
# home-rooted project keeps working; only INFERENCE is barred from $HOME.
test_start "explicit CLAUDE_PROJECT_DIR=\$HOME is still honored"
got="$(
  export CLAUDE_PROJECT_DIR="$FAKE_HOME" HOME="$FAKE_HOME"
  unset MAUDE_PROJECT_DIR_OVERRIDE
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$FAKE_HOME" "explicit \$HOME honored"

# ── 7. A trailing slash on $HOME must not defeat the guard ────────────
test_start "\$HOME with a trailing slash is still refused"
PROC4="$TEST_TMP/proc4"
mkproc "$PROC4" 100 "claude" 1 "$FAKE_HOME"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC4" MAUDE_PROC_START_PID=100 HOME="$FAKE_HOME/"
  cd "$FAKE_HOME/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$FAKE_HOME" "trailing-slash \$HOME still refused"

# ── 8. No inference path may CREATE anything, AND NOT AT $HOME EITHER ─
# The resolver is a pure query. If it ever mkdirs, the phantom comes back by a
# different door.
#
# The first version of this test watched ONLY pwd, which is not where the harm
# lands. A mutation inserting `mkdir -p "$HOME/.maude/plugin"` — the literal
# 2026-07-30 phantom, the exact thing this file is named after — left it green.
# It now watches $HOME too, sandboxed so a real mint cannot touch the real home.
test_start "resolution creates no directories (pwd OR \$HOME)"
PROBE="$TEST_TMP/probe-nocreate"
SAFEHOME="$TEST_TMP/safehome"
mkdir -p "$PROBE/sub" "$SAFEHOME"
before="$(find "$PROBE" "$SAFEHOME" | sort)"
(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$SAFEHOME"
  cd "$PROBE/sub" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir >/dev/null
)
after="$(find "$PROBE" "$SAFEHOME" | sort)"
assert_eq "$after" "$before" "no directory created by resolution"

# ── 9. The guard must not FAIL OPEN when the environment has no HOME ──
# cron, a systemd unit with no Environment=HOME, `env -i`, `docker exec` without
# -e HOME. The first version returned ALLOW for every candidate in these cases,
# so the phantom shadowed again in exactly the unattended contexts nobody watches.
#
# Pinned as the MECHANISM, not as a fixture. A fixture cannot express this: the
# harm is a phantom at the REAL home being walked past by a process that has no
# $HOME, and a test cannot move the passwd database. So both halves are pinned
# directly — home is still found when the variable is gone, and when it cannot
# be found at all the guard refuses rather than permits.
for label in "unset" "empty"; do
  test_start "_maude_home resolves the passwd home when HOME is $label"
  got="$(
    if [ "$label" = "unset" ]; then unset HOME; else export HOME=""; fi
    . "$HOOKS_DIR/_maude-common.sh"
    _maude_home
  )"
  [ -n "$got" ] && [ -d "$got" ]
  assert_exit "$?" "0" "passwd home found with HOME $label"
done

test_start "with no HOME and no passwd lookup the guard FAILS CLOSED"
NOLOOKUP="$(make_no_binary_bin)"   # carries no getent and no id
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE HOME
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999
  PATH="$NOLOOKUP"
  cd "$FAKE_HOME/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
# Home is unknowable, so EVERY inferred candidate is refused and resolution falls
# through to pwd. A guard whose failure mode is "permit" is not a guard.
assert_eq "$got" "$FAKE_HOME/work" "refused every candidate, fell through to pwd"

# ── 10. A SYMLINKED spelling of $HOME is still $HOME ──────────────────
# bash's `pwd` is LOGICAL — it preserves the symlinked spelling you arrived
# through — and the walk-up feeds candidates from pwd/dirname. So a string
# compare against $HOME misses `/link` entirely when /link -> $HOME, and the
# phantom is accepted. This is the live route, not a theoretical one.
test_start "a symlinked spelling of \$HOME is refused"
ln -sfn "$FAKE_HOME" "$TEST_TMP/homelink"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$FAKE_HOME"
  cd "$TEST_TMP/homelink/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$TEST_TMP/homelink" "symlinked \$HOME refused"

# ── 11. Dotted and doubled spellings too ──────────────────────────────
test_start "\$HOME spelled with /. and // is refused"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$FAKE_HOME//"
  cd "$FAKE_HOME/work" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$FAKE_HOME" "doubled-slash \$HOME refused"

# ── 12. Each half of the PPID parse is pinned separately ──────────────
# `_maude_ppid` reads status's PPid: line and falls back to splitting stat on the
# last ')'. Test 1's fixture writes BOTH, so either half alone satisfies it and
# neither is individually pinned: disabling the status branch left the suite
# green, and so did garbaging the stat fallback. Two paths, one pass signal.
test_start "the status PPid parse carries the walk when stat is unparseable"
PROC5="$TEST_TMP/proc5"
mkproc "$PROC5" 100 "bash"         200 "$TEST_TMP"
mkproc "$PROC5" 200 "tmux: server" 300 "$TEST_TMP"
mkproc "$PROC5" 300 "claude"         1 "$PROJ"
printf 'no-parens-here-at-all\n' > "$PROC5/200/stat"   # only status can answer
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC5" MAUDE_PROC_START_PID=100
  cd "$TEST_TMP" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$PROJ" "status parse carried it"

test_start "the stat fallback carries the walk when status is absent"
PROC6="$TEST_TMP/proc6"
mkproc "$PROC6" 100 "bash"         200 "$TEST_TMP"
mkproc "$PROC6" 200 "tmux: server" 300 "$TEST_TMP"
mkproc "$PROC6" 300 "claude"         1 "$PROJ"
rm -f "$PROC6/200/status"                              # only stat can answer
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC6" MAUDE_PROC_START_PID=100
  cd "$TEST_TMP" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$PROJ" "stat fallback carried it"

teardown_test_env
print_summary
exit "$FAILED"
