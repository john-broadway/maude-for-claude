#!/usr/bin/env bash
# Tests for the TARGET-keyed table in hooks/scripts/maude-gate.sh.
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-07-23 three of John's irreplaceable PNGs were destroyed by
#   rm -f ~/projects/*.png ~/projects/*.jpeg
# The gate did not block it. On 2026-07-30 an audit re-ran that exact command
# against the installed 0.24.0 gate and got exit 0, alongside mv / find -delete /
# shred / truncate / shutil.rmtree of the workspace root — all exit 0 — while the
# `rm -rf <root>` control correctly exited 2.
#
# Cause: the gate's table was keyed on the VERB (`rm -rf`). A denylist of verbs
# can only ever block the verbs someone thought of. This table is keyed on the
# TARGET instead: if the thing being destroyed is a sole-copy path, the verb does
# not matter.
#
# THE RULE THIS ENCODES (John, workspace memory):
#   "NEVER glob-delete in workspace root — exact names only, only files I created."
# So:
#   BLOCK  a glob whose parent is the protected root itself   (the PNG disaster)
#   BLOCK  the protected root as a bare target, any verb      (mv/shred/rmtree/…)
#   ALLOW  an exact named file, however deep                  (ordinary work)
#   ALLOW  a deep glob inside a project                       (rm -f build/*.o)
# A gate that blocked ordinary deep deletes would be switched off within a day,
# and a gate that is off protects nothing.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

GATE="$HOOKS_DIR/maude-gate.sh"

run_gate() {
  local cmd="$1"
  ERR="$(make_bash_tool_input "$cmd" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

# $TEST_TMP is CLAUDE_PROJECT_DIR, i.e. the protected sole-copy root.
P="$TEST_TMP"
mkdir -p "$P/proj/sub" "$P/build"

# CRITICAL FIXTURE FIX (2026-07-30): lib.sh exports MAUDE_GATE_CONFIG to a path it
# never creates, so `sole_copy_paths` was EMPTY in every test while the real box
# lists the workspace root. A redteam pass found the consequence: three of the ALLOW
# rows below are FALSE on the deployed config, and the suite could not see it. Same
# shape as the autoscope incident — green suite, broken only on the real config.
# Writing a config here means the fixture matches what actually ships.
printf '{"sole_copy_paths":["%s"]}\n' "$P" > "$MAUDE_GATE_CONFIG"

# ── CONTROL ────────────────────────────────────────────────────────────
# If this stops passing, every ALLOW/BLOCK result below is meaningless.

test_start "CONTROL: rm -rf of the protected root still blocks"
run_gate "rm -rf $P"
assert_exit "$RC" "2" "control rm -rf root"

# ── The 2026-07-23 disaster class: glob at the protected root ───────────

test_start "blocks the exact 2026-07-23 command shape (glob at root)"
run_gate "rm -f $P/*.png $P/*.jpeg"
assert_exit "$RC" "2" "rm -f glob at root"

test_start "stderr names the sole-copy key so the hint is actionable"
assert_contains "$ERR" "sole-copy" "stderr mentions sole-copy"

test_start "blocks rm with no flags at all on a root glob"
run_gate "rm $P/*"
assert_exit "$RC" "2" "rm root glob"

test_start "blocks a question-mark glob at the root"
run_gate "rm -f $P/VISION.m?"
assert_exit "$RC" "2" "? glob at root"

test_start "blocks a bracket glob at the root"
run_gate "rm -f $P/[VW]ISION.md"
assert_exit "$RC" "2" "bracket glob at root"

# ── Same destruction, different verb ───────────────────────────────────

test_start "blocks mv of the protected root"
run_gate "mv $P /tmp/gone"
assert_exit "$RC" "2" "mv root"

test_start "blocks mv of a root glob out of the workspace"
run_gate "mv $P/*.md /tmp/"
assert_exit "$RC" "2" "mv root glob"

test_start "blocks find -delete under the protected root"
run_gate "find $P -name '*.md' -delete"
assert_exit "$RC" "2" "find -delete"

test_start "blocks find -exec rm under the protected root"
run_gate "find $P -type f -exec rm {} ;"
assert_exit "$RC" "2" "find -exec rm"

test_start "blocks shred of a file in the protected root"
run_gate "shred -u $P/VISION.md"
assert_exit "$RC" "2" "shred"

test_start "blocks truncate of a file in the protected root"
run_gate "truncate -s 0 $P/VISION.md"
assert_exit "$RC" "2" "truncate"

test_start "blocks dd writing over a file in the protected root"
run_gate "dd if=/dev/zero of=$P/VISION.md bs=1M count=1"
assert_exit "$RC" "2" "dd of="

test_start "blocks rsync --delete into the protected root"
run_gate "rsync -a --delete /tmp/empty/ $P/"
assert_exit "$RC" "2" "rsync --delete"

test_start "blocks a python one-liner calling shutil.rmtree on the root"
run_gate "python3 -c \"import shutil;shutil.rmtree('$P')\""
assert_exit "$RC" "2" "shutil.rmtree"

test_start "blocks a python one-liner calling os.unlink on a root file"
run_gate "python3 -c \"import os;os.unlink('$P/VISION.md')\""
assert_exit "$RC" "2" "os.unlink"

# ── Prefix escapes: the same act wearing a hat ─────────────────────────

test_start "blocks mv of the root behind an env-assignment prefix"
run_gate "FOO=1 mv $P /tmp/gone"
assert_exit "$RC" "2" "env-prefixed mv"

test_start "blocks shred of a root file behind an absolute path"
run_gate "/usr/bin/shred -u $P/VISION.md"
assert_exit "$RC" "2" "absolute-path shred"

test_start "blocks mv of the root behind exec"
run_gate "exec mv $P /tmp/gone"
assert_exit "$RC" "2" "exec-prefixed mv"

# ── FALSE POSITIVES — a gate that blocks real work gets switched off ───

# The dd / rsync / interpreter rows each carry their own intervening-arg walk.
# Those walks were unbounded, so — exactly as in the rm rows — a harmless verb in
# one command paired with a protected path in a LATER one. Measured 2026-07-30.
test_start "ALLOWS dd to a safe target with a protected path in a later command"
run_gate "dd if=/dev/zero of=/tmp/x; echo of=$P"
assert_exit "$RC" "0" "dd across a separator"

test_start "ALLOWS dd to a safe target with a protected path on a later line"
run_gate "dd if=/dev/zero of=/tmp/x
grep of=$P build.log"
assert_exit "$RC" "0" "dd across a newline"

test_start "ALLOWS rsync --delete to a safe target, protected path later"
run_gate "rsync -a --delete /tmp/src/ /tmp/dst; echo $P"
assert_exit "$RC" "0" "rsync across a separator"

# The interpreter row is the awkward one: its OWN payload legitimately contains
# `;` (import shutil;shutil.rmtree(...)), so the gap BEFORE the destructive call
# cannot exclude separators without killing the true positive above. Only the gap
# AFTER it can — which is enough, because in a real one-liner the path follows the
# call immediately, while in these false positives a `;` sits between them.
test_start "ALLOWS an interpreter deleting a safe path, protected path later"
run_gate "python3 -c \"shutil.rmtree('/tmp/x')\"; echo $P"
assert_exit "$RC" "0" "interpreter across a separator"

test_start "ALLOWS ordinary work that merely mentions a delete word and a path"
run_gate "python3 train.py; echo os.remove; cat $P/README.md"
assert_exit "$RC" "0" "unrelated words in separate commands"

test_start "ALLOWS an exact named file deep inside a project"
run_gate "rm -f $P/proj/sub/tmp.json"
assert_exit "$RC" "0" "exact deep file"

test_start "ALLOWS a deep glob inside a build dir"
run_gate "rm -f $P/build/*.o"
assert_exit "$RC" "0" "deep glob"

test_start "ALLOWS rm of a glob entirely outside the workspace"
run_gate "rm -f /tmp/scratch/*.png"
assert_exit "$RC" "0" "outside glob"

test_start "ALLOWS mv between two paths outside the workspace"
run_gate "mv /tmp/a /tmp/b"
assert_exit "$RC" "0" "outside mv"

test_start "ALLOWS mv of a deep file within the workspace"
run_gate "mv $P/proj/sub/a.txt $P/proj/sub/b.txt"
assert_exit "$RC" "0" "deep mv"

test_start "ALLOWS find without a delete action"
run_gate "find $P -name '*.py'"
assert_exit "$RC" "0" "find read-only"

test_start "ALLOWS reading a file in the protected root"
run_gate "cat $P/VISION.md"
assert_exit "$RC" "0" "cat"

test_start "ALLOWS a commit message that merely quotes a gated command"
run_gate "git commit -m \"fix: guard against rm -f $P/*.png\""
assert_exit "$RC" "0" "quoted in commit msg"

test_start "ALLOWS a heredoc doc body that mentions the shape"
run_gate "cat <<'EOF' > $P/proj/notes.md
never run mv $P /tmp/gone
EOF"
assert_exit "$RC" "0" "heredoc body"

# ── Override path: the sole-copy key is RED, so a yellow clear must not open it

test_start "a git-push token does NOT open a sole-copy block"
bash "$HOOKS_DIR/maude-clear-gate.sh" git-push >/dev/null 2>&1
run_gate "rm -f $P/*.png"
assert_exit "$RC" "2" "wrong-key token does not clear"

# ── FALSE POSITIVES found by the 2026-07-30 redteam (all were rc=2) ─────────
# Each of these destroys NOTHING or is routine work. They were blocked because the
# config-sourced target regex is depth-UNBOUNDED, so the workspace root matched any
# path beneath it. A gate that blocks these gets switched off inside one session.

test_start "ALLOWS rm of an exact deep file with the root in the CONFIG"
run_gate "rm $P/proj/sub/tmp-output.txt"
assert_exit "$RC" "0" "deep exact file, config root"

test_start "ALLOWS a deep glob with the root in the CONFIG"
run_gate "rm -f $P/build/*.o"
assert_exit "$RC" "0" "deep glob, config root"

test_start "ALLOWS mv between two deep paths with the root in the CONFIG"
run_gate "mv $P/proj/sub/a.md $P/proj/sub/b.md"
assert_exit "$RC" "0" "deep mv, config root"

test_start "ALLOWS find -name matching a file whose NAME contains 'deleted'"
run_gate "find $P/proj -name '*-deleted*.log'"
assert_exit "$RC" "0" "-delete needs a word boundary"

test_start "ALLOWS install -d creating a directory (destroys nothing)"
run_gate "install -d $P/dist"
assert_exit "$RC" "0" "install -d is additive"

test_start "ALLOWS rsync --delete when the workspace is the SOURCE (a backup)"
run_gate "rsync -av --delete $P/ /mnt/nas/backup/projects/"
assert_exit "$RC" "0" "workspace as source is a backup"

test_start "ALLOWS truncate of a deep file"
run_gate "truncate -s 0 $P/proj/sub/today.jsonl"
assert_exit "$RC" "0" "deep truncate"

test_start "ALLOWS unlink of a deep lock file"
run_gate "unlink $P/proj/sub/stale.lock"
assert_exit "$RC" "0" "deep unlink"

test_start "still BLOCKS the root glob with the root in the CONFIG"
run_gate "rm -f $P/*.png"
assert_exit "$RC" "2" "root glob still blocked"

test_start "still BLOCKS the bare root with the root in the CONFIG"
run_gate "mv $P /tmp/gone"
assert_exit "$RC" "2" "bare root still blocked"

print_summary
teardown_test_env
exit "$FAILED"
