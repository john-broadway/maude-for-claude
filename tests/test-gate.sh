#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh — the hard-block gate.
#
# Covers:
#   - real positives for every pattern key
#   - false positives that bit v0.1.5 (HEREDOC commit, in-quote substrings)
#   - token-based override mechanism (one-shot pass)

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

GATE="$HOOKS_DIR/maude-gate.sh"

# Run the gate against a synthetic command. Captures exit + stderr.
# Sets $RC and $ERR.
run_gate() {
  local cmd="$1"
  ERR="$(make_bash_tool_input "$cmd" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

# ── Real positives — every pattern key ─────────────────────────────────

test_start "gate blocks bare git push"
run_gate "git push origin main"
assert_exit "$RC" "2" "git push exit"

test_start "gate stderr on git push mentions key hint"
assert_contains "$ERR" "/maude:conscience git-push" "stderr"

test_start "gate names the file it looked in (the reader's half of the 09-02 split)"
assert_contains "$ERR" "(looked in: " "names the care file it read"
looked="$(printf '%s\n' "$ERR" | sed -n 's/^ *(looked in: \(.*\))$/\1/p' | head -1)"
case "$looked" in */.maude/plugin/care.json) ok=0;; *) ok=1;; esac
assert_exit "$ok" "0" "the named file is a .maude/plugin/care.json"
# Shape is not identity: a print naming a file the gate never read would pass the
# two checks above. The test env hands the gate CLAUDE_PROJECT_DIR, so the exact
# file it must have read is known.
assert_eq "$looked" "$CLAUDE_PROJECT_DIR/.maude/plugin/care.json" "and it is the file the gate read"

test_start "gate blocks --force"
run_gate "git push origin main --force"
assert_exit "$RC" "2" "force-push exit"

test_start "a RED-key block names the red file it looked in, not the yellow one"
assert_contains "$ERR" "(looked in: " "names the care file it read"
looked="$(printf '%s\n' "$ERR" | sed -n 's/^ *(looked in: \(.*\))$/\1/p' | head -1)"
assert_eq "$looked" "$(redclear_path)" "care-redclear.json for a red key"

test_start "gate stderr on --force says force-push"
assert_contains "$ERR" "force-push" "stderr"

test_start "gate blocks --force-with-lease"
run_gate "git push --force-with-lease origin main"
assert_exit "$RC" "2" "force-with-lease exit"

test_start "gate blocks -f"
run_gate "git push origin main -f"
assert_exit "$RC" "2" "-f exit"

test_start "gate blocks --no-verify"
run_gate "git commit -m hi --no-verify"
assert_exit "$RC" "2" "no-verify exit"

test_start "gate blocks --no-gpg-sign"
run_gate "git commit -m hi --no-gpg-sign"
assert_exit "$RC" "2" "no-gpg-sign exit"

test_start "gate blocks git reset --hard"
run_gate "git reset --hard HEAD~1"
assert_exit "$RC" "2" "reset-hard exit"

test_start "gate blocks git filter-repo"
run_gate "git filter-repo --replace-text foo"
assert_exit "$RC" "2" "filter-repo exit"

test_start "gate blocks git filter-branch"
run_gate "git filter-branch --tree-filter foo HEAD"
assert_exit "$RC" "2" "filter-branch exit"

test_start "gate blocks git commit --amend"
run_gate "git commit --amend"
assert_exit "$RC" "2" "commit-amend exit"

test_start "gate blocks rm -rf /"
run_gate "rm -rf /"
assert_exit "$RC" "2" "rm-rf-root exit"

test_start "gate blocks rm -rf *"
run_gate "rm -rf *"
assert_exit "$RC" "2" "rm-rf-glob exit"

test_start "gate blocks sudo rm -rf"
run_gate "sudo rm -rf /var/log/foo"
assert_exit "$RC" "2" "sudo-rm-rf exit"

# ── DROP TABLE — context-aware (real quoted SQL blocks; prose does not) ──────
# Pre-fix this was exactly backwards: real SQL is always quoted
# (psql -c "DROP TABLE x"), so the quote-ERASED skeleton dropped it and it
# SLIPPED THROUGH; an unquoted prose mention (echo DROP TABLE) false-blocked.
# The fix matches the content-KEPT view AND requires a SQL-client token.

test_start "gate blocks real quoted SQL: psql -c \"DROP TABLE\""
run_gate 'psql -c "DROP TABLE users"'
assert_exit "$RC" "2" "quoted DROP TABLE via psql blocks"

test_start "drop-table block names its conscience key"
assert_contains "$ERR" "drop-table" "drop-table key hint"

test_start "gate blocks single-quoted SQL: mysql -e 'DROP TABLE'"
run_gate "mysql -e 'DROP TABLE users'"
assert_exit "$RC" "2" "single-quoted DROP TABLE via mysql blocks"

test_start "gate blocks lowercase drop table via sqlite3 (case-insensitive)"
run_gate 'sqlite3 db.sqlite "drop table t"'
assert_exit "$RC" "2" "lowercase drop table blocks"

test_start "gate blocks DROP TABLE in a heredoc fed to psql"
run_gate "psql <<EOF
DROP TABLE users;
EOF"
assert_exit "$RC" "2" "heredoc-to-psql DROP TABLE blocks"

test_start "gate PASSES echo DROP TABLE (prose, no SQL client)"
run_gate "echo DROP TABLE users"
assert_exit "$RC" "0" "prose drop-table mention does not block"

test_start "gate PASSES a commit message mentioning DROP TABLE"
run_gate 'git commit -m "explain the DROP TABLE migration"'
assert_exit "$RC" "0" "commit-msg drop-table mention passes"

test_start "gate PASSES authoring a .sql file via heredoc (not executing)"
run_gate "cat > drop.sql <<EOF
DROP TABLE t;
EOF"
assert_exit "$RC" "0" "writing a .sql file is not execution"

test_start "gate PASSES a heredoc commit body mentioning drop table (no client)"
run_gate "git commit -F - <<EOF
note: migration 5 will drop table legacy_sessions
EOF"
assert_exit "$RC" "0" "heredoc prose drop-table mention passes"

# ── False positives — must NOT block ─────────────────────────────────

test_start "gate passes empty command"
run_gate ""
assert_exit "$RC" "0" "empty cmd"

test_start "gate passes git pull"
run_gate "git pull origin main"
assert_exit "$RC" "0" "git pull"

test_start "gate passes commit msg with quoted git push"
run_gate 'git commit -m "do not git push"'
assert_exit "$RC" "0" "quoted git push"

test_start "gate passes single-quoted git push"
run_gate "git commit -m 'do not git push'"
assert_exit "$RC" "0" "single-quoted git push"

test_start "gate passes echo of git push literal"
run_gate "echo 'git push'"
assert_exit "$RC" "0" "echo literal"

test_start "gate passes rm -rf /tmp/foo"
run_gate "rm -rf /tmp/foo"
assert_exit "$RC" "0" "rm -rf /tmp"

test_start "gate passes rm -rf *.tmp"
run_gate "rm -rf *.tmp"
assert_exit "$RC" "0" "rm -rf *.tmp"

test_start "gate passes rm -rf foo/bar"
run_gate "rm -rf foo/bar"
assert_exit "$RC" "0" "rm -rf relative"

test_start "gate passes branch ending in -f"
run_gate "git pull origin feature-stuff"
assert_exit "$RC" "0" "branch with -f"

test_start "gate passes HEREDOC commit message containing git push"
heredoc='git commit -m "$(cat <<'"'"'EOF'"'"'
v0.1.5 commit body mentions git push as a substring
EOF
)"'
run_gate "$heredoc"
assert_exit "$RC" "0" "HEREDOC self-block"

# ── Quoted-prose false positives (v0.10.0) — must NOT block ──────────────────
# A destructive string sitting INSIDE a quoted argument is data, not execution.
# Pre-v0.10.0 these false-blocked: the PATH patterns matched against UNQUOTED
# (quote chars stripped, CONTENT kept), so a shell separator inside quoted prose
# ( '(' / ';' / backtick ) made the quoted text read as a real subshell `rm`.
# These are the exact commands that false-blocked a read-only investigation.

test_start "gate PASSES echo with (rm -rf /) inside a quoted string"
run_gate 'echo "did the gate block a destructive bash (rm -rf / sole-copy)"'
assert_exit "$RC" "0" "paren-prose false positive"

test_start "gate PASSES echo with ; rm -rf / inside a quoted string"
run_gate 'echo "step one; rm -rf / then done"'
assert_exit "$RC" "0" "semicolon-prose false positive"

test_start "gate PASSES echo with backtick rm -rf / inside a quoted string"
run_gate 'echo "subshell `rm -rf /` example"'
assert_exit "$RC" "0" "backtick-prose false positive"

test_start "gate PASSES grep for the literal rm -rf pattern"
run_gate "grep -E 'rm -rf /' logfile.txt"
assert_exit "$RC" "0" "grep-arg false positive"

# A REAL rm whose path is quoted must STILL block — the skeleton still sees the
# bare `rm -rf` in command position (only the path was quoted away).
test_start "gate STILL blocks rm -rf with a fully-quoted root target"
run_gate 'rm -rf "/"'
assert_exit "$RC" "2" "real rm, quoted path, still blocks"

# ── HEREDOC-body false positives — must NOT block ────────────────────────────
# A heredoc body is DATA fed to a command (git commit -F -, cat > file), not
# shell structure. maude_strip_quotes erases '…'/"…" spans but NOT heredoc
# bodies, so a shell separator in heredoc prose ( ; ( | ` ) survived into the
# command-position skeleton and read as a real subshell rm — false-blocking a
# commit whose body documents rm -rf /. The rm-guard now excises heredoc bodies.
test_start "gate PASSES heredoc commit body with '; rm -rf /' prose"
run_gate "git commit -F - <<EOF
fixed bug; rm -rf / no longer fires the gate
EOF"
assert_exit "$RC" "0" "heredoc semicolon-prose passes"

test_start "gate PASSES heredoc commit body with '(rm -rf /)' prose"
run_gate "git commit -F - <<EOF
caution: a destructive (rm -rf /) is fatal
EOF"
assert_exit "$RC" "0" "heredoc paren-prose passes"

test_start "gate PASSES heredoc commit body with '| rm -rf /' prose"
run_gate "git commit -F - <<EOF
example: foo | rm -rf / is the bug
EOF"
assert_exit "$RC" "0" "heredoc pipe-prose passes"

# Intentional consequence of excising heredoc bodies (option B): an rm inside a
# heredoc fed to a SHELL is now uniformly uncaught — this is the already-
# documented shell-wrapping limitation (#3), not a new gap. The bare
# `bash <<EOF\nrm -rf /\nEOF` was ALREADY missed; only the separator-prefixed
# variant accidentally blocked. Now both pass, consistently.
test_start "gate PASSES rm -rf inside a bash heredoc (shell-wrapping, limitation #3)"
run_gate "bash <<EOF
echo hi; rm -rf /
EOF"
assert_exit "$RC" "0" "shell-heredoc rm is limitation #3, not blocked"

# v0.27.0 — the QUOTED-TEXT half of old limitation #7 is CLOSED: quoted spans
# are blanked before opener detection (with <<'EOF' delimiter-quoting protected
# first), so `echo "note << EOF"` no longer opens a phantom body. This was the
# CRITICAL from the adversarial pass: once CMD patterns used the strip, the
# phantom silently swallowed a real force-push on the next line.
test_start "gate BLOCKS rm -rf after a quoted << on an earlier line (old #7, closed)"
run_gate 'echo "note << EOF" ;
rm -rf /'
assert_exit "$RC" "2" "quoted-<< no longer eats the next line"

test_start "gate BLOCKS force-push after a quoted << (the adversarial-pass CRITICAL)"
run_gate 'echo "note << EOF"
git push --force'
assert_exit "$RC" "2" "quoted-<< phantom must not swallow a RED command"

test_start "gate BLOCKS public-publish after a quoted <<"
run_gate 'echo "see << EOF above"
gh release create v1.0.0'
assert_exit "$RC" "2" "quoted-<< phantom must not swallow public-publish"

# The delimiter-quote PROTECTION leg: a real <<'EOF' heredoc must still strip
# (its body prose naming a gated command must not fire).
test_start "gate PASSES a quoted-delimiter heredoc body naming git push"
run_gate "cat > /tmp/x <<'EOF'
docs: git push is gated in this house
EOF"
assert_exit "$RC" "0" "<<'EOF' body prose passes"

# Honest residual, pinned: an UNBALANCED quote leaves the << token visible and
# still opens a phantom body — a later real command is under-blocked. Conscious
# pin so a future change to this is a choice, not an accident.
test_start "gate residual: unbalanced quote before << still eats the next line"
run_gate 'echo "oops << EOF
rm -rf /'
assert_exit "$RC" "0" "unbalanced-quote phantom is the documented residual"

# v0.27.0 — the ARITHMETIC half of limitation #7 is CLOSED: $((a << b)) is
# blinded before heredoc detection, so it no longer opens a phantom body that
# eats a real rm on the next line. This was the documented under-block cost;
# now it blocks again.
test_start "gate BLOCKS rm -rf after letter-led arithmetic << (old #7, closed)"
run_gate 'z=$((a << b))
rm -rf /'
assert_exit "$RC" "2" "arithmetic << no longer eats the next line"

test_start "gate BLOCKS rm -rf after a <<< herestring"
run_gate 'grep foo <<< bar
rm -rf /'
assert_exit "$RC" "2" "herestring is not a heredoc opener"

# v0.27.0 — heredoc excision now covers the COMMAND patterns too. The measured
# live false-block (2026-08-08): appending a memory file whose heredoc body
# contains the words "git push" fired the push gate mid-chore.
test_start "gate PASSES a heredoc body naming git push (data, not a command)"
run_gate 'cat >> /tmp/mem.md <<EOF
the session blocked a git push when John said love
EOF'
assert_exit "$RC" "0" "heredoc push prose passes"

test_start "gate STILL blocks a real git push after a closed heredoc"
run_gate 'cat > /tmp/x <<EOF
notes
EOF
git push origin main'
assert_exit "$RC" "2" "real push after heredoc still blocks"

# Conscious pin: a push inside a heredoc-fed SHELL is limitation #3 —
# uniformly uncaught for every pattern family, stated in the gate's notes.
test_start "gate PASSES git push inside a bash heredoc (limitation #3, pinned)"
run_gate 'bash <<EOF
git push origin main
EOF'
assert_exit "$RC" "0" "shell-heredoc push is limitation #3"

# v0.27.0 — two heredocs on ONE line are legal shell; the delimiter QUEUE
# keeps body B as data (the old single-slot tracker read it as live commands).
test_start "gate PASSES rm -rf inside the second of two heredocs on one line"
run_gate 'cat <<A <<B > /dev/null
a
A
rm -rf /
B
echo ok'
assert_exit "$RC" "0" "two-heredoc queue keeps body B as data"

# ── After-separator real positives — must block ──────────────────────

test_start "gate blocks git push after &&"
run_gate "cd foo && git push"
assert_exit "$RC" "2" "&& git push"

test_start "gate blocks git push after ;"
run_gate "echo done; git push"
assert_exit "$RC" "2" "; git push"

# ── Command-substitution (v0.3.3): a gated command wrapped in `...` or $(...) ──
# must still block. Backtick was missing from the separator class, so
# `result=\`git push\`` slipped the gate silently (audit finding).
test_start "gate blocks git push inside backtick substitution"
run_gate 'out=`git push origin main`'
assert_exit "$RC" "2" "backtick git push"

test_start "gate blocks rm -rf / inside backtick substitution"
run_gate 'x=`rm -rf /`'
assert_exit "$RC" "2" "backtick rm -rf /"

test_start "gate blocks git push inside \$() substitution"
run_gate 'out=$(git push origin main)'
assert_exit "$RC" "2" "dollar-paren git push"

# ── Bypass coverage (v0.3.1): ordinary command forms must NOT slip the gate ──
# These are everyday ways to write the same command — a routine whitespace or
# `git -C <dir>` variation must not defeat a hard-block.

test_start "gate blocks git push with extra interior whitespace"
run_gate "git  push origin main"
assert_exit "$RC" "2" "double-space git push"

test_start "gate blocks git -C <dir> push"
run_gate "git -C /tmp/repo push origin main"
assert_exit "$RC" "2" "git -C push"

test_start "gate blocks git -C <dir> push --force"
run_gate "git -C /repo push --force"
assert_exit "$RC" "2" "git -C force-push"

test_start "gate blocks rm -rf / with extra whitespace"
run_gate "rm  -rf /"
assert_exit "$RC" "2" "double-space rm -rf /"

test_start "gate blocks rm -fr / (reversed flags)"
run_gate "rm -fr /"
assert_exit "$RC" "2" "rm -fr /"

test_start "gate still passes git -C <dir> pull (not a push)"
run_gate "git -C /repo pull origin main"
assert_exit "$RC" "0" "git -C pull passes"

# ── Trace events ─────────────────────────────────────────────────────

test_start "gate logs 'blocked' trace event on block"
n="$(count_trace_lines '.kind == "gate" and (.payload | startswith("blocked="))')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "blocked trace count > 0"

# ── Override mechanism ───────────────────────────────────────────────

test_start "gate respects live conscience token"
# Manually drop a token that says "git-push is cleared until far in the future".
mkdir -p "$TEST_TMP/.maude/plugin"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "0" "token allowed pass"

test_start "token clears after one use (one-shot)"
# After previous test, the token should have been removed.
remaining="$(read_care '.gate_cleared["git-push"].until // "absent"')"
assert_eq "$remaining" "absent" "token cleared"

test_start "second matching command after token-use re-blocks"
run_gate "git push origin main"
assert_exit "$RC" "2" "second push blocked again"

test_start "expired token does NOT pass"
printf '{"gate_cleared":{"git-push":{"until":1}}}\n' > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "2" "expired token blocked"

test_start "token for one key does not pass other key"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git reset --hard"
assert_exit "$RC" "2" "wrong-key token blocks"

# ── Order matters: more-specific patterns fire first ────────────────

test_start "force-push pattern fires before generic git-push"
rm -f "$(care_path)"
run_gate "git push origin main --force"
# stderr should mention force-push, not generic git-push key
assert_contains "$ERR" "force-push" "force-push specificity"

# ── jq-absent contract: the gate is fail-OPEN by design ──────────────
# A jq-free parse of the tool-input JSON is too fragile to trust as a SAFETY gate
# (it would reintroduce the v0.1.6 quote-stripping self-block risk), so with jq
# gone the gate passes everything. The user is told via the SessionStart
# jq-missing notice. This locks the contract so a future change can't silently
# flip it to fail-closed (block-everything) or make it crash.
test_start "gate fails OPEN (exit 0) on a would-be-blocked command when jq is absent"
NOJQ="$(make_nojq_bin)"
make_bash_tool_input "git push origin main" | PATH="$NOJQ" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq gate exit"

# ── Sole-copy rm -rf — generic config-driven paths ──────────────────────────
# Write a config with two deployment-specific paths. The gate should also
# block the generic defaults (workspace = $TEST_TMP, ~/.claude, any .git).
printf '{"sole_copy_paths":["/srv/app","/srv/secrets"]}\n' > "$MAUDE_GATE_CONFIG"

test_start "gate blocks rm -rf of a configured sole-copy path"
run_gate "rm -rf /srv/app"; assert_exit "$RC" "2" "configured sole-copy"

test_start "gate blocks rm -rf with interior double-slash on sole-copy"
run_gate "rm -rf $CLAUDE_PROJECT_DIR//"
assert_exit "$RC" "2" "//-bypass blocked"

test_start "gate blocks rm -rf of configured path with trailing slash"
run_gate "rm -rf /srv/app/"; assert_exit "$RC" "2" "configured sole-copy trailing slash"

test_start "gate blocks rm -rf of second configured sole-copy path"
run_gate "rm -rf /srv/secrets"; assert_exit "$RC" "2" "second configured sole-copy"

test_start "gate blocks rm -rf ~/.claude (generic default)"
run_gate "rm -rf ~/.claude"; assert_exit "$RC" "2" "tilde-claude"

test_start "gate blocks rm -rf \$HOME/.claude (generic default)"
run_gate 'rm -rf $HOME/.claude'; assert_exit "$RC" "2" "dollar-HOME-claude"

test_start "gate blocks rm -rf of a .git dir (generic default)"
run_gate "rm -rf /some/repo/.git"; assert_exit "$RC" "2" ".git dir"

test_start "gate blocks rm -rf multi-arg with sole-copy as second arg"
run_gate "rm -rf build/ /srv/app"; assert_exit "$RC" "2" "sole-copy 2nd arg"

test_start "gate blocks rm -Rf of configured path (capital R)"
run_gate "rm -Rf /srv/app"; assert_exit "$RC" "2" "capital R combined"

test_start "gate blocks rm -R of configured path (capital recursive, no force)"
run_gate "rm -R /srv/app"; assert_exit "$RC" "2" "capital R alone"

test_start "gate blocks rm -rf with double-quoted configured path"
run_gate 'rm -rf "/srv/app"'; assert_exit "$RC" "2" "double-quoted sole-copy"

test_start "sole-copy block names its conscience key"
assert_contains "$ERR" "rm-rf-sole-copy" "key hint"

test_start "gate PASSES rm -rf /tmp/foo (not a sole-copy path)"
run_gate "rm -rf /tmp/foo"; assert_exit "$RC" "0" "tmp path safe"

test_start "gate PASSES rm -rf /tmp/build (safe path outside any sole-copy tree)"
run_gate "rm -rf /tmp/build"; assert_exit "$RC" "0" "tmp build dir ok"

# ── The arg-walk must stop at the end of ITS OWN command ────────────────────
# The "target in any argument position" group was ([^[:space:]]+[[:space:]]+)*.
# [[:space:]] includes \n, and `;` / `&&` / `|` are themselves non-space, so the
# walk absorbed separators as ordinary tokens and ran to the end of the whole
# script. Any harmless `rm -rf` then paired with any protected path appearing
# ANYWHERE later — and the refusal named rm-rf-sole-copy for an rm that never
# touched a protected path. Measured on a real 14-line probe, 2026-07-30:
# `rm -rf "$S"` on line 1 blocked because line 14 mentioned a <workspace> path.
# Over-blocking is the safe direction, but a refusal that states the wrong reason
# is a lying refusal, and a gate that blocks ordinary scripts gets switched off.
test_start "gate PASSES harmless rm and a protected path in separate commands (newline)"
run_gate "rm -rf /tmp/safe
echo /srv/app/x.sh"; assert_exit "$RC" "0" "newline-separated"

test_start "gate PASSES harmless rm and a protected path in separate commands (semicolon)"
run_gate "rm -rf /tmp/safe; echo /srv/app/x.sh"; assert_exit "$RC" "0" "semicolon-separated"

test_start "gate PASSES harmless rm and a protected path in separate commands (&&)"
run_gate "rm -rf /tmp/safe && echo /srv/app/x.sh"; assert_exit "$RC" "0" "and-separated"

test_start "gate PASSES harmless rm and a protected path in separate commands (pipe)"
run_gate "rm -rf /tmp/safe | grep /srv/app"; assert_exit "$RC" "0" "pipe-separated"

test_start "gate PASSES harmless rm with a protected path many lines later"
run_gate "rm -rf /tmp/safe
echo filler
echo filler
echo filler
cat /srv/app/x.sh"; assert_exit "$RC" "0" "8 lines apart"

# The same walk feeds rm-rf-root and rm-rf-glob; a bare / or * in a LATER
# command must not be attributed to an earlier harmless rm.
test_start "gate PASSES harmless rm and a bare / argument in a later command"
run_gate "rm -rf /tmp/safe; ls /"; assert_exit "$RC" "0" "root arg later"

test_start "gate PASSES harmless rm and a glob in a later command"
run_gate "rm -rf /tmp/safe; echo *"; assert_exit "$RC" "0" "glob later"

# Load-bearing: narrowing the walk must NOT reopen the real multi-arg case.
test_start "gate STILL blocks sole-copy as a later arg of the SAME rm"
run_gate "rm -rf /tmp/ok /srv/app"; assert_exit "$RC" "2" "same-command 2nd arg"

test_start "gate STILL blocks sole-copy as the third arg of the SAME rm"
run_gate "rm -rf /tmp/a /tmp/b /srv/app"; assert_exit "$RC" "2" "same-command 3rd arg"

test_start "gate STILL blocks a real rm -rf in the SECOND command of a chain"
run_gate "echo starting; rm -rf /srv/app"; assert_exit "$RC" "2" "real rm after separator"

test_start "gate STILL blocks rm -rf / as a later arg of the SAME rm"
run_gate "rm -rf /tmp/ok /"; assert_exit "$RC" "2" "same-command root 2nd arg"

# The walk stops at ; & | ONLY. ( ) and backtick must stay walkable, because
# mid-argument they are command SUBSTITUTION, not a new command — excluding them
# would turn these real destructive commands into silent passes.
# These assert the KEY, not just exit 2. Written first as exit-only, they passed
# under a mutation that broke exactly what they were meant to pin, because a
# SECOND table (sole-copy-target) was blocking instead and exit 2 cannot tell the
# two apart. An exit code is not a reason.
test_start "gate STILL blocks with a \$() substitution between rm and the target"
run_gate 'rm -rf $(echo tmpdir) /srv/app'; assert_exit "$RC" "2" "dollar-paren arg"
assert_contains "$ERR" "rm-rf-sole-copy" "dollar-paren caught by the rm -rf table"

test_start "gate STILL blocks with a backtick substitution between rm and the target"
run_gate 'rm -rf `echo tmpdir` /srv/app'; assert_exit "$RC" "2" "backtick arg"
assert_contains "$ERR" "rm-rf-sole-copy" "backtick caught by the rm -rf table"

test_start "gate STILL blocks the non-rm verb table across an intervening arg"
run_gate "mv /tmp/ok /srv/app"; assert_exit "$RC" "2" "mv onto sole-copy"
assert_contains "$ERR" "sole-copy-target" "mv caught by the target table"

test_start "gate PASSES a non-rm verb and a protected path in separate commands"
run_gate "mv /tmp/a /tmp/b; echo /srv/app/x.sh"; assert_exit "$RC" "0" "mv then unrelated echo"

test_start "gate PASSES gh pr list (read-only)"
run_gate "gh pr list"; assert_exit "$RC" "0" "gh pr list ok"

test_start "gate PASSES git commit -m 'do not git push' (CANARY)"
run_gate 'git commit -m "do not git push"'; assert_exit "$RC" "0" "canary commit-msg git push"

# RESOLVED v0.10.0: was an accepted fail-closed false-block. The skeleton-guard
# (maude_rm_in_command_position) now reads a commit message as quoted DATA, not
# execution — the "; rm -rf /srv/app" lives entirely inside the quoted -m
# argument, so the quote-ERASED skeleton shows no command-position rm and the
# gate passes. (A REAL rm whose rm-and-flags are unquoted STILL blocks even if
# only the path is quoted — see "real rm, quoted path, still blocks" above.)
test_start "gate PASSES commit message containing ; rm -rf /srv/app (quoted data, not execution)"
run_gate 'git commit -m "; rm -rf /srv/app"'; assert_exit "$RC" "0" "semicolon-in-commit is quoted data"

# ── Public-publish ──────────────────────────────────────────────────────────
test_start "gate blocks gh release create"
run_gate "gh release create v1.0 dist/*"; assert_exit "$RC" "2" "gh release"

test_start "gate blocks uv publish"
run_gate "uv publish"; assert_exit "$RC" "2" "uv publish"

test_start "gate blocks twine upload"
run_gate "twine upload dist/*"; assert_exit "$RC" "2" "twine"

test_start "gate blocks hf upload"
run_gate "hf upload john-broadway/x file"; assert_exit "$RC" "2" "hf"

test_start "public-publish block names its conscience key"
assert_contains "$ERR" "public-publish" "key hint"

test_start "gate PASSES an ordinary gh pr list (not a publish)"
run_gate "gh pr list"; assert_exit "$RC" "0" "gh read ok"

# ── v0.10.0: red-key self-clear backstop ─────────────────────────────────────
# Claude must not self-authorize a RED key by running the clear-script via the
# Bash TOOL (which fires this hook). John's ! line runs in his shell and skips
# PreToolUse hooks, so it is unaffected. SOFT: a direct care.json Write bypasses
# this (gate is Bash-only) — the harness deny-rules are the real layer.
rm -f "$(care_path)"

test_start "gate BLOCKS Claude-Bash invoking the red clear-script"
run_gate 'bash /x/hooks/scripts/maude-clear-gate.sh rm-rf-sole-copy --john'
assert_exit "$RC" "2" "red self-clear via Bash blocked"

test_start "red-self-clear block names it John's hand"
assert_contains "$ERR" "John" "block message names John"

test_start "gate BLOCKS red clear-script even with a quoted script path"
run_gate 'bash "/x/hooks/scripts/maude-clear-gate.sh" force-push --john'
assert_exit "$RC" "2" "quoted-path red self-clear blocked"

test_start "gate PASSES Claude-Bash invoking the clear-script for a YELLOW key"
run_gate 'bash /x/hooks/scripts/maude-clear-gate.sh git-push'
assert_exit "$RC" "0" "yellow self-clear via Bash allowed"

# ── v0.10.1: RED tokens are honored ONLY from care-redclear.json ─────────────
rm -f "$(care_path)" "$(redclear_path)"
mkdir -p "$TEST_TMP/.maude/plugin"
# config so /srv/app is a sole-copy target (rm-rf-sole-copy is a RED key)
printf '{"sole_copy_paths":["/srv/app"]}\n' > "$MAUDE_GATE_CONFIG"

test_start "gate HONORS a red token placed in care-redclear.json"
printf '{"gate_cleared":{"rm-rf-sole-copy":{"until":%d}}}\n' $(($(date +%s)+600)) > "$(redclear_path)"
run_gate "rm -rf /srv/app"
assert_exit "$RC" "0" "red token in redclear file passes"

test_start "gate does NOT honor a red token placed in care.json (the lock)"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"rm-rf-sole-copy":{"until":%d}}}\n' $(($(date +%s)+600)) > "$(care_path)"
run_gate "rm -rf /srv/app"
assert_exit "$RC" "2" "red token in care.json is ignored"

test_start "gate BLOCKS a Bash redirect that writes care-redclear.json"
rm -f "$(care_path)" "$(redclear_path)"
run_gate 'echo {} > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "redirect to redclear blocked"

test_start "gate BLOCKS appending to care-redclear.json"
run_gate 'printf x >> /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "append to redclear blocked"

test_start "gate BLOCKS tee to care-redclear.json"
run_gate 'echo {} | tee /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "tee to redclear blocked"

# v0.13.0: net widened beyond redirect/tee to the cp/mv/dd "pre-staged token"
# shapes the v0.10.1 net missed (honest residual: an interpreter still slips it).
test_start "gate BLOCKS cp of a pre-staged token over care-redclear.json"
run_gate 'cp /tmp/staged.json /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "cp to redclear blocked"

test_start "gate BLOCKS mv onto care-redclear.json"
run_gate 'mv /tmp/staged.json /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "mv to redclear blocked"

test_start "gate BLOCKS dd of=care-redclear.json"
run_gate 'dd if=/tmp/staged.json of=/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "dd to redclear blocked"

test_start "gate BLOCKS chmod of care-redclear.json"
run_gate 'chmod 666 /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "chmod of redclear blocked"

test_start "gate BLOCKS ln symlink-swap onto care-redclear.json"
run_gate 'ln -sf /tmp/evil.json /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "ln to redclear blocked"

test_start "gate still PASSES a harmless read of care-redclear.json"
run_gate 'cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "reading the redclear file is fine"

test_start "gate still PASSES a grep of care-redclear.json (read)"
run_gate 'grep until /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "grepping the redclear file is fine"

# ── Newline-separated commands must still block (CMD_START bypass — fixed 2026-06-30) ──
# A command on its own line is a real, separate command. maude_strip_quotes / maude_unquote
# flattened '\n'→' ' before matching, so the CMD_START anchor (which treats ; & | ( ` as a
# boundary but NOT a space) saw the gated command mid-line and passed it. The flatten now uses
# ';' so a newline reads as a command boundary. Covers yellow + RED command keys + a RED path key.
test_start "gate blocks newline-separated git push"
run_gate "$(printf 'echo hi\ngit push origin main')"
assert_exit "$RC" "2" "newline git-push blocks"

test_start "gate blocks newline-separated git push --force (RED key)"
run_gate "$(printf 'echo hi\ngit push --force origin main')"
assert_exit "$RC" "2" "newline force-push blocks"

test_start "gate blocks newline-separated rm -rf / (RED path key)"
run_gate "$(printf 'echo hi\nrm -rf /')"
assert_exit "$RC" "2" "newline rm-rf-root blocks"

test_start "gate blocks newline + indented git push"
run_gate "$(printf 'echo hi\n  git push origin main')"
assert_exit "$RC" "2" "newline-indented git-push blocks"

# ── Path traversal / .. resolution integration tests (Task 3) ─────────────────
test_start "gate blocks rm -rf /tmp/.. (resolves to root)"
run_gate "rm -rf /tmp/.."
assert_exit "$RC" "2" "trailing-dotdot blocked"

test_start "gate does NOT block rm -rf /tmp/x/../safe (resolves off-root)"
run_gate "rm -rf /tmp/x/../safe"
assert_exit "$RC" "0" "mid-dotdot allowed"

# ── Task 4: transparent command-position prefix bypasses (#6/#7/#8) ──────────

# positives — should now block
test_start "gate blocks /bin/rm -rf / (absolute-path invocation #6)"
run_gate "/bin/rm -rf /"
assert_exit "$RC" "2" "abs-path rm"

test_start "gate blocks command rm -rf / (#7)"
run_gate "command rm -rf /"
assert_exit "$RC" "2" "command-builtin rm"

test_start "gate blocks FOO=1 rm -rf / (#8)"
run_gate "FOO=1 rm -rf /"
assert_exit "$RC" "2" "env-assign rm"

test_start "gate blocks FOO=1 git push --force (#8 generalises to all patterns)"
run_gate "FOO=1 git push --force"
assert_exit "$RC" "2" "env-assign force-push"

test_start "gate blocks /usr/bin/git push (#6 generalises)"
run_gate "/usr/bin/git push origin main"
assert_exit "$RC" "2" "abs-path git push"

# false-block traps — must still PASS (exit 0)
test_start "gate does NOT block rmdir"
run_gate "rmdir /tmp/emptydir"
assert_exit "$RC" "0" "rmdir allowed"

test_start "gate does NOT block /usr/bin/rmdir"
run_gate "/usr/bin/rmdir /tmp/emptydir"
assert_exit "$RC" "0" "abs rmdir allowed"

test_start "gate does NOT block a command named mycommand"
run_gate "mycommand --recursive /tmp"
assert_exit "$RC" "0" "mycommand allowed"

# ── Task 8: shell-wrapping inspection (#3) ───────────────────────────────────
# Literal bash -c / eval payloads are now recursively inspected. A gated inner
# command blocks with its own key (so /maude:conscience <key> clears it). An
# uninspectable wrapper (variable/interpolated payload) emits a non-blocking
# whisper and exits 0.

test_start "gate blocks bash -c 'rm -rf /' with inner key"
run_gate "bash -c 'rm -rf /'"
assert_exit "$RC" "2" "wrapped rm blocked"
assert_contains "$ERR" "rm-rf-root" "wrapped rm key"

test_start "gate blocks sh -c \"git push --force\""
run_gate 'sh -c "git push --force"'
assert_exit "$RC" "2" "wrapped force-push blocked"

test_start "gate blocks nested bash -c sh -c rm"
run_gate "bash -c \"sh -c 'rm -rf /'\""
assert_exit "$RC" "2" "nested wrapped blocked"

test_start "gate WHISPERS (exit 0) on bash -c with variable payload"
run_gate 'bash -c "rm -rf $VAR"'
assert_exit "$RC" "0" "opaque not blocked"
assert_contains "$ERR" "can't inspect" "opaque whisper text"

test_start "gate passes bash -c 'ls' silently"
run_gate "bash -c 'ls'"
assert_exit "$RC" "0" "literal-safe allowed"
assert_eq "$ERR" "" "no whisper on safe literal"

print_summary
teardown_test_env
exit $FAILED
