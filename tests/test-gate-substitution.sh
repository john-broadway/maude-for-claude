#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: separators inside substitutions, line continuations, unquoted heredoc bodies, double-quoted spans.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

# ── a wrapped LATER command keeps the greedy match (lens round 3 on 1da5501) ──────────
# `sudo git push -f` alone passes both gates (CMD_START/PREFIX do not know wrappers; a
# pre-existing hole). On a plain command the greedy `.*` carried an EARLIER `git push`
# across the separator into it and blocked RED by accident. The narrow match must not
# take that away: a segment starting with a wrapper keeps the whole command greedy.
rm -f "$(care_path)"
# Listed wrappers and unlisted ones alike (lens round 4: a denylist of wrappers missed 48
# of 95 words; the rule is an allowlist of inert command words now).
for w in "sudo" "sudo -u x" "env" "/usr/bin/env" "time" "timeout 5" "xargs" "ssh h" "pct exec 100 --" "docker exec c" "eval" "." "FOO=1 sudo" "busybox" "chronic"; do
  test_start "an earlier plain push still carries into: $w git push -f"
  run_gate "git push origin main; $w git push -f"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "and RED, as before"
done
test_start "a control keyword segment keeps the greedy match too"
run_gate "git push a; if true; then git push -f; fi"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
test_start "a wrapped segment through a PIPE keeps the greedy match too"
run_gate "git push a | sudo git push -f"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
# `git` with a global option GIT does not know is a wrapper too (lens round 5): the verb
# is hidden, and only the earlier greedy carry ever caught it.
for g in "git --no-pager" "git -p" "git --paginate" "git --work-tree=x" "git --bare" "git -P" "git -c alias.x=push x -f;git"; do
  test_start "an earlier plain push still carries into: $g push -f"
  run_gate "git push origin main; $g push -f"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
done
# A git subcommand that RUNS its arguments is a wrapper (lens round 6).
for g in "git submodule foreach" "git submodule foreach --recursive" "git bisect run" "git for-each-repo --config=r.x" "git difftool -x" "git p"; do
  test_start "an earlier plain push still carries into: $g git push -f"
  run_gate "git push origin main; $g git push -f"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
done
# An UNLISTED subcommand keeps the greedy match even when it is harmless (config): the
# list is an allowlist, and nothing outside it narrows (lens round 7).
test_start "an unlisted git subcommand keeps the greedy match: git config"
run_gate "git push origin main; git config alias.x push -f"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
test_start "an amend behind git submodule foreach after a plain commit still blocks"
run_gate "git commit -m x; git submodule foreach git commit --amend"
assert_exit "$RC" "2" "blocked"
test_start "a reset --hard behind git bisect run after a plain reset still blocks"
run_gate "git reset a; git bisect run git reset --hard"
assert_exit "$RC" "2" "blocked"
test_start "a rebase -x after a plain push keeps the greedy match"
run_gate "git push a; git rebase -x git-push-f main"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
test_start "an amend behind git --no-pager after a plain commit still blocks"
run_gate "git commit -m x && git --no-pager commit --amend"
assert_exit "$RC" "2" "blocked"
test_start "a reset --hard behind git --no-pager after a plain reset still blocks"
run_gate "git reset a; git --no-pager reset --hard"
assert_exit "$RC" "2" "blocked"
# The inert boundary: `cat` is a prefix of `catchsegv`, `cp` of `cpulimit`. Without the
# word boundary both read as inert (lens round 5 mutation m7).
for w in "catchsegv" "cpulimit -l 5" "gitk" "echoer"; do
  test_start "a word that merely BEGINS with an inert word is not inert: $w"
  run_gate "git push origin main; $w git push -f"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
done
test_start "a wrapper in a MIDDLE segment keeps the greedy match too"
run_gate "git push a; sudo true; git worktree remove --force x"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before: the greedy match carried across"
test_start "a wrapper in the FIRST segment keeps the greedy match too"
run_gate "sudo git push a; git push -f && git worktree remove --force x"
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "Maude [RED]:" "RED, as before"
# The inert words are what make the intended shape narrow; each is pinned by a line
# that would be RED under the greedy match and is YELLOW under the narrow one.
for w in "rm -f x" "echo -f" "ls --hard" "cat x; rm -f y" "tee -a x" "mkdir -p x; rm -f y"; do
  test_start "an inert later segment stays narrow: git push a && $w"
  run_gate "git push origin main && $w"
  printf '%s' "$ERR" | grep -q "force-push"; assert_exit "$?" "1" "not a force-push"
done
# Every inert word, individually: dropping any one from the list must red a test.
for w in echo ls rm cd true false tee cat grep head tail sleep test mkdir cp mv touch wc sort date pwd printf; do
  test_start "inert word pinned: $w"
  run_gate "git push origin main && $w --force x"
  printf '%s' "$ERR" | grep -q "force-push"; assert_exit "$?" "1" "narrow: $w is inert"
done
test_start "git with a plain subcommand is inert (the intended shape)"
run_gate "git push origin main && git worktree remove --force x"
printf '%s' "$ERR" | grep -q "force-push"; assert_exit "$?" "1" "narrow"
test_start "an amend behind env after a plain commit still blocks"
run_gate "git commit -m x && env git commit --amend"
assert_exit "$RC" "2" "blocked"
test_start "a reset --hard behind sudo after a plain reset still blocks"
run_gate "git reset HEAD~1;sudo git reset --hard"
assert_exit "$RC" "2" "blocked"
test_start "a reset --hard behind timeout after a plain reset still blocks"
run_gate "git reset x; timeout 5 git reset --hard"
assert_exit "$RC" "2" "blocked"
# The intended shape, unchanged by the wrapper rule: no wrapper, the flag stays with its
# own command.
test_start "control: the intended plain shape is still narrow"
run_gate "git push -q origin main && git worktree remove --force /tmp/wt"
printf '%s' "$ERR" | grep -q "force-push"; assert_exit "$?" "1" "not a force-push"
# `|` is a boundary like `;` and `&`; the earlier tests only crossed `&&` and `;`, so a
# SAME_CMD of `[^;&]*` survived every one of them (lens round 3).
test_start "a pipe is a command boundary for the narrow match"
run_gate "git push -q origin main | git worktree remove --force /tmp/wt"
printf '%s' "$ERR" | grep -q "force-push"; assert_exit "$?" "1" "not a force-push across a pipe"

# ── lens on fc0bf3a: a separator INSIDE a command substitution is not a separator ──
# `[^;&|]*` stopped at the `|` in `$(… | …)`, so `git reset $(x | y) --hard` passed and a
# force-push through `$(…)` fell to the YELLOW git-push key. With a substitution anywhere
# the gate keeps its old greedy match: never less than it blocked before.
rm -f "$(care_path)"
for c in 'git reset $(true | true) --hard' 'git reset `git rev-parse HEAD | cut -c1-7` --hard' \
         'git reset $(true;true) --hard' 'git commit -m $(echo hi|tr a-z A-Z) --amend' \
         'git commit -m x `echo a|echo b` --amend'; do
  test_start "substitution with a separator before the flag still blocks: $c"
  run_gate "$c"; assert_exit "$RC" "2" "blocked"
done
test_start "an escaped separator before the flag is a literal and still blocks"
run_gate 'git commit -m fish\&chips --amend'; assert_exit "$RC" "2" "blocked"
run_gate 'git reset HEAD\;x --hard'; assert_exit "$RC" "2" "blocked"
test_start "process substitution with a separator before the flag still blocks"
run_gate 'git reset <(true | true) --hard'; assert_exit "$RC" "2" "blocked"
for c in 'git push $(git remote | head -1) --force' 'git push $(git remote | head -1) -f' \
         'git push `git remote | head -1` --force-with-lease' 'git push $(true;echo origin) --force'; do
  test_start "force-push through a substitution stays RED: $c"
  run_gate "$c"; assert_contains "$ERR" "force-push" "names force-push"; assert_contains "$ERR" "RED" "RED key"
done

# ── lens round 2 on bf22c9d: 61 regressions through constructs a substring list missed ──
# `${x//|/z}`, bracket globs, redirects (`2>&1`, `&>`, `>|`) and a backslash line
# continuation all carry a `;` `&` `|` that is not a boundary. The narrow match now runs
# only on a command made of plain word characters and separators; everything else keeps
# the old greedy match.
rm -f "$(care_path)"
LC=$'git reset origin \\\n--hard'
LCA=$'git commit -m msg \\\n--amend'
for c in 'git reset ${x//|/z} --hard' 'git commit -m msg ${x//|/z} --amend' 'git reset ${y:-a|b} --hard' \
         'git reset fil[|]e --hard' 'git reset 2>&1 --hard' 'git commit -m msg 2>&1 --amend' \
         'git -C /tmp/repo reset ${x//|/z} --hard' "bash -c 'git commit -m msg \${x//|/z} --amend'" \
         "$LC" "$LCA"; do
  test_start "a non-boundary separator before the flag still blocks: $(printf '%q' "$c")"
  run_gate "$c"; assert_exit "$RC" "2" "blocked"
done
LCP=$'git push origin \\\nmain --force'
for c in 'git push origin ${x//|/z} --force' 'git push origin main &>/dev/null --force' \
         'git push origin main >| --force' "$LCP"; do
  test_start "a force-push past a non-boundary separator stays RED: $(printf '%q' "$c")"
  run_gate "$c"; assert_contains "$ERR" "force-push" "names force-push"; assert_contains "$ERR" "RED" "RED key"
done
test_start "the live false match stays fixed: a plain push then a worktree cleanup"
run_gate "git push -q origin main && git worktree remove --force /var/lib/x/scratchpad/wt4"
assert_not_contains "$ERR" "force-push" "stderr names no force-push"

# The two allowlist rules no test could see removed (mutations "unclosed-sq" and
# "dq-anything" survived round 9's run): on the OPENER's own line, an unclosed quote and a
# `"..."` holding `$(` each end the stripping, so the body bash may treat differently is read
# as commands. Each test makes that one construct the only thing wrong, beside a control.
test_start "control: a closed quote after the opener keeps the body stripped"
run_gate $'cat <<Z \'x\'\ngit push --force\nZ'
assert_exit "$RC" "0" "passes"
test_start "an UNCLOSED quote after the opener ends the stripping: the body is read"
run_gate $'cat <<Z \'x\ngit push --force\nZ'
assert_exit "$RC" "2" "blocked"
test_start "control: a plain double-quoted word after the opener keeps the body stripped"
run_gate $'cat <<Z "x"\ngit push --force\nZ'
assert_exit "$RC" "0" "passes"
test_start "a double quote holding \$( after the opener ends the stripping: the body is read"
run_gate $'cat <<Z "$(x)"\ngit push --force\nZ'
assert_exit "$RC" "2" "blocked"

# The allowlist reads bytes under LC_ALL=C, so what it accepts cannot move with the locale:
# in en_US.UTF-8 bash's [A-Za-z0-9_] matches é, ǅ and ٣, and without the pin `<<Zé` read as
# a delimiter and the body was stripped (mutation "no-locale" survived round 9's run).
WIDE_LOC=""
for _l in en_US.UTF-8 en_US.utf8 C.UTF-8; do
  LC_ALL="$_l" bash -c '[[ "é" =~ ^[A-Za-z]$ ]]' 2>/dev/null && { WIDE_LOC="$_l"; break; }
done
if [ -n "$WIDE_LOC" ]; then
  test_start "under a locale whose ranges take é ($WIDE_LOC), a non-ASCII delimiter is still unreadable: the body is read"
  ERR="$(make_bash_tool_input $'cat <<Zé\ngit push --force\nZé' | LC_ALL="$WIDE_LOC" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
  assert_exit "$RC" "2" "blocked, as under C"
  test_start "control: the same locale keeps an ASCII heredoc body stripped"
  ERR="$(make_bash_tool_input $'cat <<Z\ngit push --force\nZ' | LC_ALL="$WIDE_LOC" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
  assert_exit "$RC" "0" "passes"
else
  printf '  skip  no installed locale widens [A-Za-z] past ASCII here: the locale pin is untested on this host\n'
fi

# ── An unquoted heredoc body is not text: bash runs its substitutions (lens 2026-10-06) ──
# The stripper dropped every body after a provable opener, but with an unquoted delimiter
# bash expands $(...) and `...` inside the body, so `cat <<EOF` / `$(git push --force)` /
# `EOF` ran the push and passed the gate (rc 0 on the branch AND on main v0.33.x), while
# `echo $(git push --force)` alone blocks. A quoted delimiter is never expanded.
test_start "an unquoted heredoc body's \$(...) is read, not stripped"
run_gate $'cat <<EOF\n$(git push --force)\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "an unquoted heredoc body's backticks are read, not stripped"
run_gate $'cat <<EOF\n`git push -f`\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "a later body line's substitution is read too"
run_gate $'cat <<EOF\nplain text first\nmore text $(git push origin main --force) here\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "the <<- form's unquoted body is read the same way"
run_gate $'cat <<-EOF\n\t$(git push -f)\n\tEOF'
assert_exit "$RC" "2" "blocks"
test_start "a substitution inside \${...} is read"
run_gate $'cat <<EOF\n${X:-$(git push --force)}\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "a substitution split by a backslash-newline is read (bash joins the lines first)"
run_gate $'cat <<EOF\nx $\\\n(git push --force)\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "a backtick split the same way is read"
run_gate $'cat <<EOF\nx \\\n`git push -f`\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "a substitution whose command word is split by a backslash-newline is read joined"
run_gate $'cat <<EOF\n$(git pu\\\nsh --force)\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "the same split through the first word"
run_gate $'cat <<EOF\n$(g\\\nit push -f)\nEOF'
assert_exit "$RC" "2" "blocks"
test_start "control: a QUOTED delimiter's body is never expanded, so it stays stripped"
run_gate $'cat <<\'EOF\'\n$(git push --force)\nEOF'
assert_exit "$RC" "0" "passes"
test_start "control: an unquoted body with no substitution stays stripped"
run_gate $'cat <<EOF\nnotes: never git push --force to main\nEOF'
assert_exit "$RC" "0" "passes"

# ── A double-quoted span is not text where bash expands it (lens 2026-10-07) ─────────
# maude_strip_quotes erased every "..." span, but bash runs $(...) and `...` inside double
# quotes: `echo "$(git push --force)"` passed (rc 0, v0.33.x and v0.34.0), and so did the
# commit-message shape with an unquoted heredoc inside it. Single quotes stay literal.
test_start "a \$(...) inside double quotes is read"
run_gate 'echo "$(git push --force)"'
assert_exit "$RC" "2" "blocks"
test_start "a backtick inside double quotes is read"
run_gate 'echo "`git push -f`"'
assert_exit "$RC" "2" "blocks"
test_start "the commit-message shape: an unquoted heredoc inside \"\$(cat ...)\""
run_gate $'git commit -m "$(cat <<EOF\nmsg\n$(git push --force)\nEOF\n)"'
assert_exit "$RC" "2" "blocks"
test_start "an apostrophe inside double quotes does not open a single-quoted span"
run_gate $'echo "it\'s $(git push -f) and \'later"'
assert_exit "$RC" "2" "blocks"
test_start "a substitution inside \${...} inside double quotes is read"
run_gate 'echo "${X:-$(git push --force)}"'
assert_exit "$RC" "2" "blocks"
test_start "a substitution nested in a substitution is read"
run_gate 'echo "$(echo "$(git push --force)")"'
assert_exit "$RC" "2" "blocks"
test_start "control: prose in double quotes still reads as text"
run_gate 'git commit -m "docs: never git push --force to main"'
assert_exit "$RC" "0" "passes"
test_start "control: the canonical commit-message heredoc (quoted delimiter) still passes"
run_gate $'git commit -m "$(cat <<\'EOF\'\nfix: never git push --force\nEOF\n)"'
assert_exit "$RC" "0" "passes"
test_start "control: a substitution inside SINGLE quotes is literal and passes"
run_gate $'echo \'"$(git push --force)"\''
assert_exit "$RC" "0" "passes"
test_start "control: a harmless substitution in a message passes"
run_gate 'git commit -m "release on $(date +%F): git push --force is not in this"'
assert_exit "$RC" "0" "passes"

# The quote scan runs on every Bash call, so its cost is a hook budget. A first draft
# was quadratic: index() on copied tails and string building ran past 300 s on a 418 KB
# command, and substr() per char ran past 60 s under one-true-awk (macOS). Every awk on
# the box, a ~1.7 MB quote-dense command, through a FILE: the first version of this test
# passed it as one argv string, which Linux caps at 128 KB, so exec failed, every awk
# "returned" the same empty output and the test was green on nothing. The output must now
# hold all 24,000 substitutions. A planted per-char-concatenation emit takes ~20 s here.
BIGF="$TEST_TMP/bigcmd.txt"
awk 'BEGIN { for (i = 0; i < 24000; i++) printf "echo \"line %d with it\047s text $(date) and `id` here\" \047single %d\047 ;\n", i, i }' > "$BIGF"
QREF=""
for A in awk original-awk mawk gawk; do
  command -v "$A" >/dev/null 2>&1 || continue
  test_start "the quote scan of a ~1.7 MB command finishes in seconds ($A)"
  mkdir -p "$TEST_TMP/qshim-$A"; ln -sf "$(command -v "$A")" "$TEST_TMP/qshim-$A/awk"
  T0=$SECONDS
  PATH="$TEST_TMP/qshim-$A:$PATH" bash -c '. "$1"; maude_strip_quotes "$(cat "$2")"' _ "$HOOKS_DIR/_maude-common.sh" "$BIGF" > "$TEST_TMP/qout-$A"
  [ $((SECONDS - T0)) -le 12 ]; assert_exit "$?" "0" "took $((SECONDS - T0)) s (bound 12)"
  assert_eq "$(grep -o ';date;' "$TEST_TMP/qout-$A" | wc -l | tr -d ' ')" "24000" "every substitution read"
  QOUT="$(cksum < "$TEST_TMP/qout-$A")"
  [ -n "$QREF" ] || QREF="$QOUT"
  assert_eq "$QOUT" "$QREF" "same output as the first awk"
done

# The ) that closes a $( is found the way bash finds it (lens 2026-10-08): a ) inside
# quotes, in a # comment or in a case pattern does not close it. Before, each of these
# closed the $( early, the rest fell back into the erased span, and bash ran the push.
test_start "a ) inside single quotes in a substitution does not close it"
run_gate $'echo "$(echo \')\'; git push --force o x)"'
assert_exit "$RC" "2" "blocks"
test_start "a ) inside double quotes in a substitution does not close it"
run_gate 'echo "$(echo ")"; git push --force o x)"'
assert_exit "$RC" "2" "blocks"
test_start "a case pattern's ) does not close it"
run_gate 'echo "$(case x in a) echo hi;; esac; git push --force o x)"'
assert_exit "$RC" "2" "blocks"
test_start "a ) in a # comment does not close it"
run_gate $'echo "$(echo # )\ngit push --force o x)"'
assert_exit "$RC" "2" "blocks"
test_start "a backslash-escaped quote in ANSI-C \$'...' does not end the span"
run_gate $'echo $\'a\\\'b\' "$(git push --force)" \'x\''
assert_exit "$RC" "2" "blocks"
# Lens round 2 (2026-10-08). A quote after $$ (the PID) or after an escaped \$ is a PLAIN
# single quote: treating it as ANSI-C let \' run on and swallow the real command (a
# regression of 954b09f: both blocked at 896308d).
test_start "a quote after \$\$ is plain, not ANSI-C"
run_gate $'echo $$\'a\\\'; git push --force #\''
assert_exit "$RC" "2" "blocks"
test_start "a quote after an escaped \\\$ is plain, not ANSI-C"
run_gate $'echo \\$\'a\\\'; git push --force #\''
assert_exit "$RC" "2" "blocks"
test_start "control: a real ANSI-C span still hides its own text, and prose after it stays erased"
run_gate $'echo $\'it\\\'s\' "never git push --force"'
assert_exit "$RC" "0" "passes"
test_start "control: \$# and \${#x} are not comments"
run_gate 'echo "$(echo $# ${#x}) done; git push --force is only prose here"'
assert_exit "$RC" "0" "passes"

# A substitution's own quotes are read by the same scan (not emitted raw): bash prints
# this text and runs nothing, so the ; inside the inner quotes must not become a boundary.
test_start "control: quoted prose inside a substitution inside double quotes passes"
run_gate 'echo "$(printf "%s" "step; git push --force")"'
assert_exit "$RC" "0" "passes"

rm -f "$(care_path)"

print_summary
teardown_test_env
exit $FAILED
