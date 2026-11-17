#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: real positives, false positives, heredoc and quoted bodies, separators, bypass forms, trace events.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

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

# Not prose (2026-10-07): bash RUNS a backtick inside double quotes, so this was a real
# `rm -rf /` the test kept passing. `bash -c 'echo "see \`echo RAN\` in the doc"'` prints
# "see RAN in the doc". The ( and ; cases above are literal in double quotes and stay passing.
test_start "gate BLOCKS echo with backtick rm -rf / inside DOUBLE quotes (bash runs it)"
run_gate 'echo "subshell `rm -rf /` example"'
assert_exit "$RC" "2" "a backtick in double quotes executes"
test_start "control: the same backtick inside SINGLE quotes is literal and passes"
run_gate "echo 'subshell \`rm -rf /\` example'"
assert_exit "$RC" "0" "single quotes are literal"

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

# Excising heredoc bodies (option B) left an rm inside a heredoc fed to a SHELL
# uncaught (limitation #3). The shell parser closes it: bash reads that body as its
# program, so it is a command, not a mention (docs/gate-threat-model.md).
test_start "gate BLOCKS rm -rf inside a bash heredoc (limitation #3, closed by the parser)"
run_gate "bash <<EOF
echo hi; rm -rf /
EOF"
assert_exit "$RC" "2" "the body bash runs is read"

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

# Was the pinned residual (an UNBALANCED quote left the << token visible and opened a
# phantom body, under-blocking the next line) until 2026-10-03: the open quote is now carried
# across lines, so the `<<` inside it is text and the next line is read. The change was a
# choice, made where the pin asked for it.
test_start "an unbalanced quote before << no longer eats the next line (the quote is carried)"
run_gate 'echo "oops << EOF
rm -rf /'
assert_exit "$RC" "2" "the rm on the next line is read and blocked"

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

# Was a conscious pin (limitation #3, uncaught for every pattern family); the shell
# parser reads the body a shell is fed, so it blocks now.
test_start "gate BLOCKS git push inside a bash heredoc (limitation #3, closed by the parser)"
run_gate 'bash <<EOF
git push origin main
EOF'
assert_exit "$RC" "2" "the body bash runs is read"

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

print_summary
teardown_test_env
exit $FAILED
