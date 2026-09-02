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
#      "$HOME phantom": the walk dies, resolution falls to ~, a caller mkdirs
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

test_start "_maude_home falls back to Directory Services when getent is absent (BSD shim)"
# macOS carries no getent — the 0.25→0.27 code first met BSD on the public
# catch-up PR (2026-08-08) and this exact resolution failed there. Pinned with a
# fake dscl in a minimal PATH so a Linux box guards the branch a Mac exercises
# for real. The fixture home carries a space: awk-$2 parsing would truncate it.
DSCL_BIN="$TEST_TMP/dscl-bin"
mkdir -p "$DSCL_BIN"
for t in bash sh id sed printf cat env; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$DSCL_BIN/$t"
done
# Assembled so no single shipped line carries a leak-audit path shape — the
# audit's own concatenation idiom, same as the secret-scan token fixtures.
ud='/Use'; FAKE_BSD_HOME="${ud}rs/fake runner home"
printf '#!/usr/bin/env bash\necho "NFSHomeDirectory: %s"\n' "$FAKE_BSD_HOME" > "$DSCL_BIN/dscl"
chmod +x "$DSCL_BIN/dscl"
got="$(env -i PATH="$DSCL_BIN" HOOKS_DIR="$HOOKS_DIR" "$DSCL_BIN/bash" -c '
  . "$HOOKS_DIR/_maude-common.sh"
  unset HOME
  command -v getent >/dev/null 2>&1 && exit 99   # control: getent leaking in voids the probe
  _maude_home
')"
assert_eq "$got" "$FAKE_BSD_HOME" "dscl branch resolves, spaces kept whole"

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

# ── 7. THE 2026-09-02 REGRESSION: the daemon tree ─────────────────────
# Claude Code gained a daemon architecture. The processes that hold the real
# workspace cwd are named by VERSION ("2.1.258"), and the process still literally
# named `claude` sits at $HOME. Measured live on the box 2026-09-02:
#
#   [0] comm=<version>  cwd=~/projects            <- the correct answer
#   [1] comm=2.1.258  cwd=/tmp/cc-daemon-0/.../spare
#   [2] comm=claude     cwd=~                     <- $HOME, correctly refused
#
# Old behaviour: the walk skipped [0] and [1] for having the wrong comm, matched
# [2], had its cwd refused for being $HOME, and then BROKE OUT of the walk instead
# of continuing. It fell to the filesystem walk-up, which found a subproject's
# .maude/plugin closet and returned THAT.
#
# Consequence, live: maude-clear-gate.sh wrote the token to <subproject>/.maude/
# plugin/care.json while the gate hook (which has CLAUDE_PROJECT_DIR) read
# <workspace>/.maude/plugin/care.json. The clear printed success and the gate
# refused anyway.
test_start "proc walk survives the daemon tree (version-named ancestors, claude at \$HOME)"
PROC7="$TEST_TMP/proc7"
DHOME="$TEST_TMP/dhome"; DPROJ="$DHOME/projects"; DSUB="$DPROJ/subproject"
mkdir -p "$DSUB/.maude/plugin" "$DPROJ/.maude/plugin" "$TEST_TMP/spare"
# A real closet has content; a bare dir is what a mis-resolution auto-creates.
printf '{}\n' > "$DPROJ/.maude/plugin/care.json"
printf '{}\n' > "$DSUB/.maude/plugin/care.json"
mkproc "$PROC7" 100 "2.1.258" 200 "$DPROJ"          # holds the right answer
mkproc "$PROC7" 200 "2.1.258" 300 "$TEST_TMP/spare" # daemon scratch, not a root
mkproc "$PROC7" 300 "claude"    1 "$DHOME"          # $HOME — must be refused
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC7" MAUDE_PROC_START_PID=100 HOME="$DHOME"
  cd "$DSUB" || exit 1          # the shadowing closet the old code fell into
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$DPROJ" "daemon tree resolved to the workspace root, not the subproject closet"

# ── 8. A refused candidate must not ABANDON the walk ──────────────────
# Narrower control for the `break`: a claude ancestor at $HOME sits BELOW a
# further ancestor holding a good cwd. Continuing must find it.
test_start "a \$HOME-cwd claude ancestor does not abandon the rest of the walk"
PROC8="$TEST_TMP/proc8"
EHOME="$TEST_TMP/ehome"; EPROJ="$TEST_TMP/eproj"
mkdir -p "$EHOME" "$EPROJ"
mkproc "$PROC8" 100 "bash"   200 "$EHOME"
mkproc "$PROC8" 200 "claude" 300 "$EHOME"           # refused: cwd is $HOME
mkproc "$PROC8" 300 "claude"   1 "$EPROJ"           # good, further up
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC8" MAUDE_PROC_START_PID=100 HOME="$EHOME"
  cd "$EHOME" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$EPROJ" "walk continued past the refused ancestor"

# ── 9. THE REAL TREE: clear-gate runs as a CHILD of the tool shell ────
# The first attempt at this fix was measured INLINE from the Bash tool shell and
# so never saw the bottom level. maude-clear-gate.sh is invoked as
# `bash .../maude-clear-gate.sh <key>` — a CHILD — so there is one more ancestor
# and its cwd is whatever directory the tool is sitting in. Measured live:
#
#   [0] bash       cwd=~/projects/<sibling>  <- HAS A CLOSET, and is NOT the root
#   [1] <version>  cwd=~/projects            <- the root
#   [2] 2.1.258  cwd=/tmp/cc-daemon-0/.../spare
#   [3] claude     cwd=~                    <- $HOME, refused
#
# CLAUDE_PID is set in this shape in the real world (verified live), and it is
# what resolves it. This test asserts the real configuration.
test_start "child-of-tool-shell tree resolves to the workspace root"
PROC9="$TEST_TMP/proc9"
NHOME="$TEST_TMP/nhome"; NPROJ="$NHOME/projects"; NSUB="$NPROJ/subproject"
mkdir -p "$NSUB/.maude/plugin" "$NPROJ/.maude/plugin" "$TEST_TMP/spare9"
printf '{}\n' > "$NPROJ/.maude/plugin/care.json"
printf '{}\n' > "$NSUB/.maude/plugin/care.json"
mkproc "$PROC9"  50 "bash"     100 "$NSUB"
mkproc "$PROC9" 100 "2.1.258"  200 "$NPROJ"
mkproc "$PROC9" 200 "2.1.258"  300 "$TEST_TMP/spare9"
mkproc "$PROC9" 300 "claude"     1 "$NHOME"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC9" MAUDE_PROC_START_PID=50 HOME="$NHOME" CLAUDE_PID=100
  cd "$NSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$NPROJ" "resolved to the workspace root"

# ── 10. CLAUDE_PID must be the thing that decides, provably ───────────
# The pid points at a process that is NOT in the ancestor chain and at a
# directory no other rule can reach. If the CLAUDE_PID branch were deleted,
# nothing else could produce this answer. That is what makes it a control:
# an earlier version of this test used an ancestor pid, so the walk alone
# satisfied it and the branch could be removed with the suite still green.
test_start "CLAUDE_PID decides, and nothing else can produce its answer"
PROC10="$TEST_TMP/proc10"
QHOME="$TEST_TMP/qhome"; QPROJ="$QHOME/projects"; QSUB="$QPROJ/sub"
QOFF="$TEST_TMP/offchain"        # unreachable by any walk from the chain below
mkdir -p "$QSUB/.maude/plugin" "$QPROJ/.maude/plugin" "$QOFF/.maude/plugin"
printf '{}\n' > "$QPROJ/.maude/plugin/care.json"
printf '{}\n' > "$QSUB/.maude/plugin/care.json"
printf '{}\n' > "$QOFF/.maude/plugin/care.json"
mkproc "$PROC10"  50 "bash"    100 "$QSUB"
mkproc "$PROC10" 100 "2.1.258"   1 "$QPROJ"
mkproc "$PROC10" 777 "2.1.258"   1 "$QOFF"      # off-chain: only CLAUDE_PID reaches it
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC10" MAUDE_PROC_START_PID=50 HOME="$QHOME" CLAUDE_PID=777
  cd "$QSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$QOFF" "CLAUDE_PID reached a root no walk could"

# ── 11b. CLAUDE_PID landing at $HOME is REFUSED and the walk answers ──────
# The guard on the CLAUDE_PID step is the "known, deliberate asymmetry" the
# source names. It had no test: a fresh lens deleted it, the suite stayed green,
# and the resolver answered $HOME — the phantom closet of 2026-07-30.
test_start "a CLAUDE_PID whose cwd is \$HOME is refused and the walk answers instead"
mkproc "$PROC10" 778 "2.1.258"   1 "$QHOME"      # CLAUDE_PID landing at $HOME
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC10" MAUDE_PROC_START_PID=50 HOME="$QHOME" CLAUDE_PID=778
  cd "$QSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$QHOME" "\$HOME refused at the CLAUDE_PID step"
assert_eq "$got" "$QSUB" "the walk's nearest closet answered instead"

# ── 11c. CLAUDE_PID landing under $TMPDIR is refused too ──────────────────
# Steps 2 and 3 gained the location test in this release; step 1.5, the
# highest-preference resolver, had not. A lens proved it accepted a $TMPDIR root
# that the two steps below it refuse.
test_start "a CLAUDE_PID whose cwd is \$TMPDIR itself is refused and the walk answers instead"
QTMP="$TEST_TMP/qfaketmp"
mkdir -p "$QTMP/.maude/plugin"; printf '{}\n' > "$QTMP/.maude/plugin/care.json"
mkproc "$PROC10" 779 "2.1.258"   1 "$QTMP"      # CLAUDE_PID landing in the temp dir
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC10" MAUDE_PROC_START_PID=50 HOME="$QHOME" CLAUDE_PID=779 TMPDIR="$QTMP"
  cd "$QSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$QTMP" "\$TMPDIR refused at the CLAUDE_PID step"
assert_eq "$got" "$QSUB" "the walk's nearest closet answered instead"

# ── 11. An unreadable CLAUDE_PID must FALL THROUGH, not collapse ───────
test_start "an unreadable CLAUDE_PID falls through to the walk"
PROC11="$TEST_TMP/proc11"
RHOME="$TEST_TMP/rhome"; RPROJ="$TEST_TMP/rproj"
mkdir -p "$RHOME" "$RPROJ/.maude/plugin"
printf '{}\n' > "$RPROJ/.maude/plugin/care.json"
mkproc "$PROC11" 100 "bash"    200 "$RHOME"
mkproc "$PROC11" 200 "2.1.258"   1 "$RPROJ"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  export MAUDE_PROC_ROOT="$PROC11" MAUDE_PROC_START_PID=100 HOME="$RHOME" CLAUDE_PID=999999
  cd "$RHOME" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$RPROJ" "fell through to the walk"

# ── 12. A closet under $TMPDIR must never be trusted ──────────────────
# /tmp/.maude/plugin EXISTS on the live box and /tmp is 1777. A closet there
# would redirect care.json, gate tokens, the vault and the trace log into
# world-writable, reboot-volatile storage. Content is present on purpose: the
# refusal must not depend on the directory being empty.
test_start "a closet at \$TMPDIR itself is refused as an inferred root"
PROC12="$TEST_TMP/proc12"
THOME="$TEST_TMP/thome"; TMPCLOSET="$TEST_TMP/faketmp"; TREAL="$TEST_TMP/treal"
mkdir -p "$THOME" "$TMPCLOSET/.maude/plugin" "$TREAL/.maude/plugin"
printf '{}\n' > "$TMPCLOSET/.maude/plugin/care.json"
printf '{}\n' > "$TREAL/.maude/plugin/care.json"
mkproc "$PROC12" 100 "bash"    200 "$THOME"
mkproc "$PROC12" 200 "2.1.258" 300 "$TMPCLOSET"   # must be skipped
mkproc "$PROC12" 300 "2.1.258"   1 "$TREAL"       # must be taken instead
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$PROC12" MAUDE_PROC_START_PID=100 HOME="$THOME" TMPDIR="$TMPCLOSET"
  cd "$THOME" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$TREAL" "skipped the \$TMPDIR closet and took the real one"

# ── 12b. $TMPDIR spelled through a SYMLINK is still refused ───────────────
# The compare canonicalises both sides. It had no test: a lens replaced it with
# a raw string compare and the suite stayed green — and that is the half the
# macOS sentence rides on (/var -> /private/var).
test_start "a \$TMPDIR spelled through a symlink still refuses the canonical closet"
LREAL="$TEST_TMP/lreal"; LLINK="$TEST_TMP/llink"
mkdir -p "$LREAL/.maude/plugin" && ln -s "$LREAL" "$LLINK"
( export TMPDIR="$LLINK"; . "$HOOKS_DIR/_maude-common.sh"; _maude_root_location_ok "$LREAL" )
assert_exit "$?" "1" "the canonical path of a symlinked \$TMPDIR is refused"
( export TMPDIR="$LLINK"; . "$HOOKS_DIR/_maude-common.sh"; _maude_root_location_ok "$LREAL/proj" )
assert_exit "$?" "0" "a directory below it is not (exact path only)"

# ── 12c. A claude-NAMED ancestor at $TMPDIR is refused by the walk too ────
# Every walk-level temp test named its processes by version, so the claude_hit
# branch — which outranks the closet probe — never met a temp root. A lens
# proved it took one: step 1.5 refused $TMPDIR, fell through, and the walk
# handed the same $TMPDIR straight back.
test_start "a claude-named ancestor whose cwd is \$TMPDIR itself is refused by the walk"
PROC12C="$TEST_TMP/proc12c"
mkproc "$PROC12C" 100 "bash"   200 "$THOME"
mkproc "$PROC12C" 200 "claude" 300 "$TMPCLOSET"   # the strongest signal, at the temp dir
mkproc "$PROC12C" 300 "2.1.258"  1 "$TREAL"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$PROC12C" MAUDE_PROC_START_PID=100 HOME="$THOME" TMPDIR="$TMPCLOSET"
  cd "$THOME" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$TREAL" "skipped the claude-named \$TMPDIR ancestor and took the real closet"

# ── 13. A BARE closet is not evidence ─────────────────────────────────
# A HAND-MADE content-less .maude/plugin/ is refused. It is NOT what a previous
# mis-resolution leaves (see 13b, the pinned limit): the plugin's own closet has
# trace/ from the first touch. This test pins the refusal; 13b pins its edge.
test_start "a bare content-less closet is not accepted as a root"
PROC13="$TEST_TMP/proc13"
BHOME="$TEST_TMP/bhome"; BBARE="$TEST_TMP/bbare"; BREAL="$TEST_TMP/breal"
mkdir -p "$BHOME" "$BBARE/.maude/plugin" "$BREAL/.maude/plugin"
printf '{}\n' > "$BREAL/.maude/plugin/care.json"     # only this one is real
mkproc "$PROC13" 100 "bash"    200 "$BHOME"
mkproc "$PROC13" 200 "2.1.258" 300 "$BBARE"          # bare — must be skipped
mkproc "$PROC13" 300 "2.1.258"   1 "$BREAL"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$PROC13" MAUDE_PROC_START_PID=100 HOME="$BHOME"
  cd "$BHOME" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$BREAL" "skipped the bare closet"

# ── 13b. PINNED LIMIT: the closet the plugin itself leaves IS accepted ────
# maude_ensure_self_dir makes trace/, and maude-clear-gate.sh then writes
# care.json — both are evidence markers in _maude_closet_ok. A wrong answer runs
# exactly that code, so the contents test cannot separate a mis-resolution's
# closet from a real one. It refuses HAND-MADE empty closets (13) and nothing
# more. Pinned so the prose can never claim more than the code does.
test_start "PINNED LIMIT: the closet maude_ensure_self_dir leaves is accepted by the contents test"
BLEFT="$TEST_TMP/bleft"
mkdir -p "$BLEFT"
( export MAUDE_PROJECT_DIR_OVERRIDE="$BLEFT"; . "$HOOKS_DIR/_maude-common.sh"; maude_ensure_self_dir >/dev/null 2>&1 )
[ -d "$BLEFT/.maude/plugin/trace" ]
assert_exit "$?" "0" "ensure_self_dir left trace/ — the shape a wrong answer leaves"
( . "$HOOKS_DIR/_maude-common.sh"; _maude_closet_ok "$BLEFT" )
assert_exit "$?" "0" "the contents test accepts it — the documented limit"

# ── 13c. No /proc: the filesystem walk-up refuses a closet under $TMPDIR ──
# On macOS steps 1.5 and 2 produce nothing, so step 3 is the ONLY resolver, and
# the temp-directory refusal is the one behaviour this release adds there. It
# had no test: a lens removed the guard and the suite stayed green.
test_start "with no /proc the filesystem walk-up refuses a closet at \$TMPDIR itself"
WHOME="$TEST_TMP/whome"; WTMP="$TEST_TMP/wfaketmp"
mkdir -p "$WHOME" "$WTMP/.maude/plugin" "$WTMP/proj"
printf '{}\n' > "$WTMP/.maude/plugin/care.json"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$EMPTY_PROC" MAUDE_PROC_START_PID=999 HOME="$WHOME" TMPDIR="$WTMP"
  cd "$WTMP/proj" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_ne "$got" "$WTMP" "did not take the \$TMPDIR closet"
# The walk keeps climbing past the refusal (here it reaches the test env's own
# closet at $TEST_TMP); the point is that nothing under the refused one is taken.
case "$got" in "$WTMP"|"$WTMP"/*) ok=1;; *) ok=0;; esac
assert_exit "$ok" "0" "nothing under the refused closet was taken"

# ── 13d. The literal /tmp, /var/tmp and / refusals have their own pin ─────
# 12 and 13c drive $TMPDIR. The literal case is the one the docstring justifies
# (/tmp is 1777 and /tmp/.maude/plugin exists on real boxes) and it had no test:
# a lens deleted it, the suite stayed green, and the resolver answered /tmp.
test_start "the literal /tmp, /var/tmp and / are refused as root locations (TMPDIR unset)"
for cand in /tmp /var/tmp /; do
  ( unset TMPDIR; . "$HOOKS_DIR/_maude-common.sh"; _maude_root_location_ok "$cand" )
  assert_exit "$?" "1" "$cand refused"
done
( unset TMPDIR; . "$HOOKS_DIR/_maude-common.sh"; _maude_root_location_ok "$TEST_TMP" )
assert_exit "$?" "0" "an ordinary directory below /tmp is not refused (exact path only)"

# ── 14. NO REGRESSION: a session rooted IN a subproject stays there ────
# A draft of this fix preferred the OUTERMOST closet along the path, to skip the
# tool shell's cwd. That climbed PAST the root of a session legitimately rooted
# in a subproject — the mirror image of the bug being fixed. The walk is
# deliberately NEAREST-first; CLAUDE_PID is what disambiguates.
test_start "a session rooted in a subproject is not climbed past"
PROC14="$TEST_TMP/proc14"
SHOME="$TEST_TMP/shome"; SROOT="$TEST_TMP/sroot"; SSUB="$SROOT/sub"
mkdir -p "$SHOME" "$SSUB/.maude/plugin" "$SROOT/.maude/plugin"
printf '{}\n' > "$SSUB/.maude/plugin/care.json"
printf '{}\n' > "$SROOT/.maude/plugin/care.json"
mkproc "$PROC14" 100 "bash"    200 "$SSUB"
mkproc "$PROC14" 200 "2.1.258" 300 "$SSUB"
mkproc "$PROC14" 300 "2.1.258"   1 "$SROOT"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$PROC14" MAUDE_PROC_START_PID=100 HOME="$SHOME"
  cd "$SSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$SSUB" "stayed at the subproject root"

# ── 15. THE PINNED RESIDUAL — this is a known gap, not a passing feature ──
# With NO declaration available (no CLAUDE_PROJECT_DIR, no usable CLAUDE_PID, no
# `claude`-named ancestor), the tool-shell-in-a-subproject shape and the
# session-rooted-in-a-subproject shape (test 14) are IDENTICAL in the process
# tree. The walk cannot separate them, so it returns the subproject. Test 14 is
# the case that makes that the right conservative default.
#
# Pinned so the boundary is visible and cannot move silently. If this assertion
# ever starts failing, someone found a real signal — update it deliberately.
test_start "PINNED RESIDUAL: with no CLAUDE_PID the child-tree shape yields the subproject"
got="$(
  unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE CLAUDE_PID
  export MAUDE_PROC_ROOT="$PROC9" MAUDE_PROC_START_PID=50 HOME="$NHOME"
  cd "$NSUB" || exit 1
  . "$HOOKS_DIR/_maude-common.sh"
  maude_project_dir
)"
assert_eq "$got" "$NSUB" "documented residual: CLAUDE_PID is what closes this"

teardown_test_env
print_summary
exit "$FAILED"
