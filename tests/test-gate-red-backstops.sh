#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: the red backstops read text as text, and the security review on c7cfaa6.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

# ── The red backstops read text as text (2026-10-08, live) ──────────────────────────
# A vault note written through a heredoc carried the clear line for a RED key, and the
# red-self-clear backstop blocked the note: it grepped the quote-stripped command with the
# heredoc BODIES still in it, while every pattern in the table had read a body as data since
# v0.27.0. Documenting the trap sprang it. The two red backstops now read the same
# body-stripped view the table reads, and keep the bodies only where a shell is fed the
# heredoc (that body runs). The plain invocation stays blocked: that is the control.

test_start "control: the plain red self-clear invocation is still blocked"
run_gate "bash $CR infra-destructive --marker abc"
assert_exit "$RC" "2" "plain invocation blocked"

test_start "a note heredoc QUOTING the red clear line passes (the 10-08 vault note)"
run_gate "cat >> note.md <<'EOF'
Six failed commands. The line he was handed:
  ! bash $CR infra-destructive --marker <link>
EOF"
assert_exit "$RC" "0" "heredoc text passes"

test_start "the same text with the key in a plain line after the heredoc is still blocked"
run_gate "cat >> note.md <<'EOF'
notes
EOF
bash $CR infra-destructive --marker abc"
assert_exit "$RC" "2" "the command after the body is read"

test_start "a heredoc FED TO A SHELL carrying the red clear line is blocked (that body runs)"
run_gate "bash <<'EOF'
bash $CR infra-destructive --marker abc
EOF"
assert_exit "$RC" "2" "shell-fed body blocked"

test_start "a python heredoc that prints the red clear line passes"
run_gate "python3 - <<'EOF'
print(\"bash $CR sole-copy-target --owner\")
EOF"
assert_exit "$RC" "0" "interpreter body is text"

test_start "a note heredoc mentioning a redirect into care-redclear.json passes"
run_gate "cat >> note.md <<'EOF'
the gate blocks: echo {} > /x/.maude/plugin/care-redclear.json
EOF"
assert_exit "$RC" "0" "redclear-write backstop reads the body as text"

test_start "control: the redirect itself is still blocked"
run_gate 'echo {} > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "redclear write blocked"

test_start "control: a redirect into care-redclear.json after a text heredoc is still blocked"
run_gate "cat >> note.md <<'EOF'
notes
EOF
echo {} > /x/.maude/plugin/care-redclear.json"
assert_exit "$RC" "2" "the command after the body is read"

test_start "the backstop still expands ~ on the stripped view (quoted tilde path)"
run_gate "echo {} > \"~/.maude/plugin/care-redclear.json\""
assert_exit "$RC" "2" "tilde path still resolves"

# The lens on the change above: a body written INTO A RUNNABLE FILE is the moment for the
# reflex rail (the second step, `bash f.sh`, carries no clear line); main blocked these by
# accident and the first cut passed them. An allowlist of doc shapes keeps the note text.
test_start "a heredoc that writes the red clear line into a .sh file is blocked at write time"
run_gate "cat > f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "script authoring blocked"

test_start "a Makefile authored with the clear line and run in the same command is blocked"
run_gate "cat > Makefile <<'EOF'
a:
	bash $CR force-push --marker abc
EOF
make a"
assert_exit "$RC" "2" "blocked"

test_start "a heredoc into ~/.bashrc carrying the clear line is blocked"
run_gate "cat <<'EOF' > ~/.bashrc
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "a heredoc into a path held in a variable keeps its body (cannot read the target: closed)"
run_gate "cat <<'EOF' > \"\$OUT\"
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "a heredoc tee'd into a script file is blocked"
run_gate "cat <<'EOF' | tee x.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "control: the same body into a .txt note is text"
run_gate "cat >> notes.txt <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "doc-shaped target passes"

test_start "control: a .sh heredoc that does NOT carry a clear line passes"
run_gate "cat > f.sh <<'EOF'
echo hello
EOF"
assert_exit "$RC" "0" "ordinary script authoring passes"

test_start "a note heredoc mentioning cp into care-redclear.json passes (the verb net reads the stripped view)"
run_gate "cat >> note.md <<'EOF'
do not run: cp staged.json /x/.maude/plugin/care-redclear.json
EOF"
assert_exit "$RC" "0" "text"

test_start "control: the cp itself is still blocked"
run_gate 'cp staged.json /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "verb net holds"

test_start "the red key LAST, followed by ; or a newline, is still the red key (UNQUOTED joins lines with ;)"
run_gate "bash $CR --marker abc force-push; echo hi"
assert_exit "$RC" "2" "separator after the key"
run_gate "bash $CR --marker abc force-push
echo hi"
assert_exit "$RC" "2" "newline after the key"
run_gate "bash $CR --marker abc force-push && echo hi"
assert_exit "$RC" "2" "&& after the key"
run_gate "(bash $CR --marker abc force-push)"
assert_exit "$RC" "2" ") after the key"
run_gate "bash $CR --marker abc force-push | cat"
assert_exit "$RC" "2" "| after the key"
run_gate "{ bash $CR --marker abc force-push;}"
assert_exit "$RC" "2" "; } after the key"
run_gate "x=\`bash $CR --marker abc force-push\`"
assert_exit "$RC" "2" "backtick after the key"

# The security lens on the fold: every redirect target on the opener line counts, a sink is
# not a file, and a doc-shaped file the same command runs is run.
test_start "a script target hidden behind a doc-shaped stderr redirect is still a script"
run_gate "cat <<'EOF' > f.sh 2> err.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "a script target after a pipe to cat, or after 2>&1, is still a script"
run_gate "cat <<'EOF' | cat > f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "| cat > f.sh blocked"
run_gate "cat <<'EOF' 2>&1 > f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "2>&1 > f.sh blocked"
run_gate "cat <<'EOF' &> f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "&> f.sh blocked"
run_gate "cat <<'EOF' >| f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" ">| f.sh blocked"

test_start "the csh spelling >& f.sh, tee with a second operand, sudo tee, sponge, dd: all scripts"
run_gate "cat <<'EOF' >& f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" ">& f.sh blocked"
run_gate "cat <<'EOF' | tee notes.md f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "tee second operand blocked"
run_gate "cat <<'EOF' | sudo tee f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sudo tee blocked"
run_gate "cat <<'EOF' | sponge f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sponge blocked"
run_gate "cat <<'EOF' | dd of=f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "dd blocked"

test_start "a doc-shaped file run on the SAME line as its opener keeps its body"
run_gate "cat <<'EOF' > notes.md; bash notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "a doc-shaped target written with no space (>notes.md) and run afterwards is still seen"
run_gate "cat <<'EOF' >notes.md; bash notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "blocked"

test_start "readers that can write, and an interpreter with -c, are closed"
run_gate "cat <<'EOF' | sed 'w f.sh'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sed w blocked"
run_gate "cat <<'EOF' | sort -o f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sort -o blocked"
run_gate "cat <<'EOF' | python3 -c 'import sys,os; open(\"f.sh\",\"w\").write(sys.stdin.read())'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "python -c blocked"
run_gate "cat <<'EOF' >&1x
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "&1x is a file, not an fd"
run_gate "cat <<'EOF' | tee -- -f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "tee -- -f.sh blocked"
run_gate "cat <<'EOF' | tee --bogus notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "an unknown dash word is a possible file: closed"

# Lens round 2: the one-line greedy scan was wrong in both directions. Text shapes one
# quote or one stderr redirect away from the 10-08 note blocked; a writer BEFORE the
# heredoc passed. The scan is a quote-aware walk of the opener lines only now.
test_start "a QUOTED doc target is still a doc (the 10-08 note, one quote away)"
run_gate "cat >> \"note.md\" <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "double-quoted"
run_gate "cat >> 'note.md' <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "single-quoted"
run_gate "cat <<'EOF' >>\"\$HOME/memory/now_x.md\"
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "a variable path ending in .md"

test_start "a stderr redirect carries no body: 2>>err.log and 2>/tmp/x.sh beside a note are text"
run_gate "cat <<'EOF' >> notes.md 2>>err.log
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "2>>err.log"
run_gate "cat >> note.md 2>/tmp/x.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "2>/tmp/x.sh"

test_start "plain text names a note takes are text: README, NOTE.MD, page.html, run.log"
for tgt in README NOTE.MD page.html run.log NOTES; do
  run_gate "cat <<'EOF' > $tgt
bash $CR force-push --marker abc
EOF"
  assert_exit "$RC" "0" "$tgt passes"
done

test_start "a BODY line that documents a heredoc into a script is text (only opener lines are read)"
run_gate "cat >> note.md <<'EOF'
the trap: cat <<X > run.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "body line is not an opener"

test_start "a quoted -> or > on the opener line is not a redirect"
run_gate "gh pr create --title \"a -> b\" --body-file - <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "quoted arrow"
run_gate "git commit -m \"x << y > z\" -F - <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "quoted angle"

test_start "a WRITER before the heredoc takes the body: tee, dd of=, sponge, cp /dev/stdin"
run_gate "tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "tee f.sh"
run_gate "dd of=f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "dd of="
run_gate "sponge f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sponge"
run_gate "cp /dev/stdin f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "cp /dev/stdin"

test_start "stdout dup'd onto a file-backed fd (2>f.sh >&2, 3>f.sh >&3) is a script"
run_gate "cat <<'EOF' 2>f.sh >&2
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "2>f.sh >&2"
run_gate "cat <<'EOF' >&3 3>f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" ">&3 3>f.sh (dup before the file)"

test_start "stdout sent to /dev/stderr beside 2>f.sh, an ANSI-C quoted target, a writer behind sudo or an assignment, exec, a group closer: all scripts"
run_gate "cat <<'EOF' >/dev/stderr 2>f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" ">/dev/stderr 2>f.sh"
run_gate "cat <<'EOF' > \$'f.sh\\x00.md'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "ANSI-C quoted name"
run_gate "sudo -u root tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "sudo -u root tee"
run_gate "FOO=1 nice -n 5 tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "assignment + nice -n"
run_gate "exec 3>f.sh
cat <<'EOF' >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "exec on an earlier line"
run_gate "if true; then exec 3>f.sh; fi
cat <<'EOF' >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "exec after a keyword"
run_gate "sudo --user root unknowncmd f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a wrapper peeled down to an unknown word is closed"
run_gate "sudo --user root cat <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a wrapper peeled down to anything but a writer is closed (sudo cat)"
run_gate "sudo -n tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a wrapper option of unknown arity is closed"
run_gate "cat <<'EOF' >/dev/fd/../../tmp/f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a traversal through /dev/fd is a path, not an alias"
run_gate "ex\"\"ec 3>f.sh
cat <<'EOF' >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "exec spelled through quotes"
run_gate "cat <<'EOF' >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a dup onto an fd the line does not open is closed"
run_gate "cat <<'EOF' 3>notes.md >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "control: a dup onto an fd the line opens on a note is text"
run_gate "cat <<'EOF' 3>&4 4>f.sh >&3
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "an fd chain above 2 is closed"
run_gate "time -a tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "time -a takes no argument: tee is the word"
# A heredoc opened inside a group is never stripped (maude_strip_heredocs reads `{ cat <<EOF`
# as no opener), so the backstops read it whole: blocked whatever the closer redirects to.
# Fail-closed and older than this change; pinned so a stripper change cannot open it unseen.
run_gate "{ cat <<'EOF'
bash $CR force-push --marker abc
EOF
} > f.sh"
assert_exit "$RC" "2" "group closer redirect"

test_start "control: the same shapes into a note are text"
run_gate "sudo -u root tee -a notes.md <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "sudo tee -a notes.md"
run_gate "cat <<'EOF' >/dev/stdout
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "/dev/stdout alone"

test_start "control: stdout dup'd onto a doc-backed fd, or onto stderr with no file, is text"
run_gate "cat <<'EOF' 2>notes.md >&2
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "2>notes.md >&2"
run_gate "cat <<'EOF' >&2
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" ">&2 alone"

# Lens round 3 on the tokenizer: the five that were still live.
test_start "the upper-case doc names (LICENSE, CHANGELOG, AUTHORS) are docs"
for tgt in LICENSE CHANGELOG AUTHORS NOTICE; do
  run_gate "cat <<'EOF' >> $tgt
bash $CR force-push --marker abc
EOF"
  assert_exit "$RC" "0" "$tgt passes"
done

test_start "a note whose BODY names its own file is still a note (the 10-08 shape, self-referencing)"
run_gate "cat >> now_maude.md <<'EOF'
see now_maude.md for the rest
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "body mention is not a run"
# RESIDUAL, pinned: a later command that merely NAMES the file (`git add notes.md`,
# `cat notes.md`) reads as "named again" and closes. Telling a runner word from a reader
# word there is a decision not yet made; fail-closed, and only when the body carries the
# red line. (Lens round 3, M2.)
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
git add notes.md"
assert_exit "$RC" "2" "a later git add still closes (pinned residual)"

test_start "the named-again count is what catches a non-shell runner on a later line"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 notes.md"
assert_exit "$RC" "2" "python3 notes.md"

test_start "a body handed to xargs or a scheduler before the heredoc is closed"
run_gate "xargs tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "xargs tee"
run_gate "crontab - <<'EOF'
* * * * * bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "crontab -"
run_gate "at now <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "at now"

test_start "a redirect on a loop or if closer line takes the body"
run_gate "while true; do cat <<'EOF'
bash $CR force-push --marker abc
EOF
break; done > f.sh"
assert_exit "$RC" "2" "done > f.sh"
run_gate "if true; then cat <<'EOF'
bash $CR force-push --marker abc
EOF
fi > f.sh"
assert_exit "$RC" "2" "fi > f.sh"
run_gate "while true; do
cat <<'EOF'
bash $CR force-push --marker abc
EOF
done > f.sh"
assert_exit "$RC" "2" "opener on its own line inside a loop, closer at line start"
run_gate "cat <<'EOF' \\
> f.sh
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a continued opener line is one line"
run_gate "cat <<'EOF' >> notes.md
bash $CR force-push --marker abc
EOF
echo done > summary.txt"
assert_exit "$RC" "0" "control: the word done inside a later command is not a closer"

# ── the security review on c7cfaa6 (2026-10-16), folded 2026-10-18 ───────────────────
test_start "a closer word glued to its operator is still a closer (review 1: done>f.sh)"
# (An opener on the `do`/`then` line is closed by the compound-opener rule already; the
# opener stands on its own line here so the closer arm is what decides.)
run_gate "while true; do
cat <<'EOF'
bash $CR force-push --marker abc
EOF
done>f.sh"
assert_exit "$RC" "2" "done>f.sh"
run_gate "if true; then
cat <<'EOF'
bash $CR force-push --marker abc
EOF
fi>f.sh"
assert_exit "$RC" "2" "fi>f.sh"
run_gate "if true; then
cat <<'EOF'
bash $CR force-push --marker abc
EOF
fi|tee f.sh"
assert_exit "$RC" "2" "fi|tee f.sh"
run_gate "while true; do
cat <<'EOF'
bash $CR force-push --marker abc
EOF
done&>f.sh"
assert_exit "$RC" "2" "done&>f.sh"
run_gate "while true; do
cat <<'EOF'
bash $CR force-push --marker abc
EOF
done>notes.md"
assert_exit "$RC" "0" "control: done>notes.md is a doc"

test_start "a backslash on a command line ends the stripping, odd or even: the body is read raw (review 2)"
# The stripper's allowlist admits no backslash outside a delimiter, so a continued line and
# an escaped backslash alike hand every later line back whole; the runnable-file reader's
# line join therefore never decides a verdict. Pinned here so the join can be measured.
run_gate "cat <<'EOF' \\\\
> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "an even run of backslashes: read raw, closed"
run_gate "cat <<'EOF' \\
> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "an odd run: read raw, closed"
# The one line the stripper admits with a trailing backslash is a COMMENT, and bash never
# joins a comment line: a join here glued the next opener into the comment's segment and
# lost its writer (the advisor on this fold, 2026-10-18).
run_gate "echo # \\
tee f.sh <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "a comment ending in a backslash does not swallow the next opener"
run_gate "echo # \\
tee notes.md <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "control: the same with a doc target passes"

test_start "a doc-shaped file named by ANOTHER body is run, not read (review 3: the interpreter body)"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 - <<'PY'
import os; os.system('bash notes.md')
PY"
assert_exit "$RC" "2" "a python body that names the note"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
cat <<'EOF2' >> MEMORY.md
- [x](notes.md)
EOF2"
assert_exit "$RC" "2" "pinned cost: a second note that links the first closes when the first carries the red line"
run_gate "cat <<'EOF' > notes.md
a note with no red line
EOF
cat <<'EOF2' >> MEMORY.md
- [x](notes.md)
EOF2"
assert_exit "$RC" "0" "control: the same two-note write without a red line passes"
run_gate "cat >> now_maude.md <<'EOF'
see now_maude.md for the rest
bash $CR force-push --marker abc
EOF
git commit -am \"\$(cat <<'MSG'
docs: the note, in one command with its commit
MSG
)\""
assert_exit "$RC" "0" "control: a self-naming note plus a commit-message heredoc is still the 10-08 shape"
run_gate "cat >> now_maude.md <<'EOF'
see now_maude.md for the rest
bash $CR force-push --marker abc
EOF
git commit -am \"\$(cat <<'MSG'
docs: now_maude.md
MSG
)\""
assert_exit "$RC" "2" "found 2026-10-18: a commit message that names the note closes it (with the red line)"

print_summary
teardown_test_env
exit $FAILED
