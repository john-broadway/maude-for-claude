#!/usr/bin/env bash
# A word known only at run time in command position (`$x git push`, `${x:-} rm -rf /`,
# `$(true) gh release create v1`), glued to the verb (`${x}git push`), or in a wrapper's
# operand slot (`timeout $x 5 git push --force`, `sudo $x -u root rm -rf /`): with x unset
# the word vanishes, the slots shift, and bash runs the words after it. The gate passed every
# one rc 0 (2026-11-05; found as a "tier B residual" the day before; every RED key passed
# behind two characters). Two readers, both pinned here: the regex tables (a run-time word
# is a transparent prefix, like an env-assignment; a glued one is the path prefix the ABS
# row already skips; a run-time word among git's global options is skipped) and the judge
# (the consumed and the vanished readings, every hit of either; not read whole, so no yellow
# token opens it; the block line prints the words as typed).
#
# The tables-alone leg runs with NO python3 on the PATH: `MAUDE_GATE_JUDGE_BUDGET=0` turns
# every unkeyed command into a parser-budget RED and so can never show a pass (the lens on
# 4b3cd91). With no python3 the tables' verdict stands, as on a box without it.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

HOOKS_DIR="$(dirname "$0")/../hooks/scripts"
GATE="$HOOKS_DIR/maude-gate.sh"
NOPY="$(make_no_binary_bin python3)"

run_gate() {
  ERR="$(make_bash_tool_input "$1" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}
run_tables() {
  ERR="$(make_bash_tool_input "$1" | PATH="$NOPY" bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

P="$TEST_TMP"
printf '{"sole_copy_paths":["%s"]}\n' "$P" > "$MAUDE_GATE_CONFIG"

# ── the judge and the tables together: every key behind a run-time word ─────────────
while IFS=$'\t' read -r cmd want; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "blocked: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "$want" "names its key"
done <<EOF
\$x git push	git push detected
\${x} git push	git push detected
\${x:-} git push	git push detected
\$1 git push	git push detected
\$@ git push	git push detected
\$x \$y git push	git push detected
\$x\$y git push	git push detected
\$(true) git push	git push detected
\`true\` git push	git push detected
\$((0)) git push	git push detected
"\$x" git push	git push detected
\$x command git push	git push detected
true; \$x git push	git push detected
git \$x push	git push detected
git \${x:-} push --force	force-push
\$x git push --force	force-push
\$x git reset --hard	reset --hard
\$x git commit --amend	amend
\$x gh release create v1	public-facing publish
\$x rm -rf /	wipes the system
\$x rm -rf $P	sole-copy
\$x mv $P /tmp/x	sole-copy
\${x}git push	git push detected
\$(true)git push	git push detected
\${x}\${y}git push	git push detected
\${x}rm -rf /	wipes the system
\${x}rm -rf $P	sole-copy
\${x}/bin/rm -rf /	wipes the system
\${x}gh release create v1	public-facing publish
gi\${x}t push	git push detected
git pu\${x}sh --force	force-push
git -C \$x . push --force	force-push
git -c \$x a=b push --force	force-push
git --git-dir \$x .git push --force	force-push
sudo \$x -u root rm -rf /	wipes the system
sudo \$x -u root git push --force	force-push
timeout \$x 5 git push --force	force-push
timeout -s KILL \$x 5 rm -rf /	wipes the system
timeout \${x:-} 5 gh release create v1	public-facing publish
flock \$x /tmp/l rm -rf /	wipes the system
taskset \$x 1 git push --force	force-push
nice \$x -n 5 git push --force	force-push
env \$x -C /tmp git push --force	force-push
xargs \$x -I{} git push --force	force-push
\$x\$SHELL -c 'git push'	git push detected
\${x}\$BASH -c 'rm -rf /'	wipes the system
\$x sudo -u \$u rm -rf /	wipes the system
nice -n \$n \$x rm -rf /	wipes the system
\$x env -C \$d git push --force	force-push
env git -C \$d \$x push --force	force-push
\$x sudo -u \$u git push	git push detected
sudo \$a r \$b r \$c r rm -rf /	wipes the system
sudo \$a r \$b r \$c r \$d r rm -rf /	wipes the system
git -c \$a x=y \$b x=y \$c x=y \$d x=y push --force	force-push
sudo \$a r \$b r \$c r \$d r \$e r rm -rf /	wipes the system
timeout \$t1 5 \$t2 5 \$t3 5 \$t4 5 git push --force	force-push
\$(printf '') mv $P /tmp/x	sole-copy
\$(printf '')rm -rf /	wipes the system
sudo \$(printf '') mv $P /tmp/x	sole-copy
\$(true 1) git push --force	force-push
\$(:) gh release create v1	public-facing publish
git \$(true) push --force	force-push
git \`true\` push --force	force-push
sudo \$a \$b r \$c r \$d r rm -rf /	wipes the system
EOF

# ── the tables alone (no python3 on the box) ─────────────────────────────────────────
while IFS=$'\t' read -r cmd want; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "no python3: $cmd"
  run_tables "$cmd"
  assert_exit "$RC" "2" "blocked by the tables"
  assert_contains "$ERR" "$want" "names its key"
done <<EOF
\$x git push	git push detected
\${x} git push	git push detected
\${x:-} git push	git push detected
\$1 git push	git push detected
\$@ git push	git push detected
\$x \$y git push	git push detected
\$x\$y git push	git push detected
\$(true) git push	git push detected
\$x\$(true) git push --force	force-push
\$((0)) git push	git push detected
git \$x push	git push detected
git \$x push --force	force-push
git \${x:-} push --force	force-push
\$x git \$y push --force	force-push
\$x git push --force	force-push
\$x git reset --hard	reset --hard
\$x rm -rf /	wipes the system
\$x rm -rf $P	sole-copy
\$x mv $P /tmp/x	sole-copy
\${x}git push	git push detected
\$(true)git push	git push detected
\${x}\${y}git push	git push detected
\${x}rm -rf /	wipes the system
\${x}rm -rf $P	sole-copy
\$(printf '') mv $P /tmp/x	sole-copy
\$(printf '')rm -rf /	wipes the system
sudo \$(printf '') mv $P /tmp/x	sole-copy
\$(true 1) git push --force	force-push
\$(:) gh release create v1	public-facing publish
git \$(true) push --force	force-push
git \`true\` push --force	force-push
\${x}/bin/rm -rf /	wipes the system
\${x}gh release create v1	public-facing publish
EOF

# ── the label: the words as typed reach stderr (the lens on 4b3cd91, finding 4) ──────
while IFS=$'\t' read -r cmd said; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "label carries the typed words: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "read through the shell parser as: $said" "the typed words on stderr"
done <<EOF
gi\${x}t push origin main	gi\${x}t push origin main
git pu\${x}sh --force	git pu\${x}sh --force
\${x}r\${y}m -rf /	\${x}r\${y}m -rf /
\$x git push	\$x git push
\$x timeout \$t git push --force	\$x timeout \$t git push --force
find / -delete	find / -delete
\$x find / -delete	\$x find / -delete
EOF

# ── the label is printed once, even where the message has no conscience sentence to cut at ─
test_start "parser-depth prints its parser label once (lens 2 on fa4225c, finding 5)"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "$(python3 -c "print('echo \$(' * 70 + 'x' + ')' * 70)")"
assert_exit "$RC" "2" "blocked"
n="$(printf '%s' "$ERR" | grep -o '(read through the shell parser as:' | wc -l | tr -d " ")"   # BSD wc pads its count
assert_eq "$n" "1" "one parser label"
test_start "a find delete names the typed words, not a made-up rm"
rm -f "$(care_path)" "$(redclear_path)"
run_gate 'find / -delete'
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "read through the shell parser as: find / -delete" "the typed words"
assert_not_contains "$ERR" "parser as: rm -rf /" "no made-up words"

# ── a yellow token does not open it: the command word is unknown until it runs ───────
for c in '$x git push' 'sudo $x git push' 'git $x push' '${x}git push' 'timeout $x 5 $y git push' 'flock $x /tmp/l $y git push' 'timeout $x 5 nice $y -n 5 git push' 'timeout $x 5 ionice $y -c 3 git push'; do
  test_start "a yellow token does not open: $c (the read is not whole)"
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "could not read all of this command" "names the partial read"
  assert_not_contains "$ERR" "Fix the syntax" "the syntax is valid: says to write the word out"
  assert_contains "$ERR" "run-time word" "says what to write out"
  assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved"
done

# ── past the cap, or a word behind every eaten pair: unreadable, refused, nothing clears ──
# lens 4 on dd9d405: discovery ate one option pair per view, so `sudo $a r $b r $c r rm -rf /`
# (a=b=c=-u) passed rc 0 and four slot words before `git push --force` read whole with no
# key. Now a word behind every eaten pair is found, and past four such words the read is
# unreadable: refused, and a yellow token does not open it.
# (With a RED verb behind them the tables key the plain form on their own, so the keyed
# shapes sit in the list above; these carry no key, and only the judge's refusal stands.)
for c in 'sudo $a r $b r $c r $d r $e r ls' 'timeout $t1 5 $t2 5 $t3 5 $t4 5 ls' 'git -c $a x=y $b x=y $c x=y $d x=y $e x=y status'; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "unreadable past the cap: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "could not read all of this command" "names the partial read"
done

# ── controls: the house convention `$CC …` / `$PYTHON …` passes, with and without python3 ─
for c in '$PYTHON script.py' '$CC -o a a.c' '${CROSS}gcc -o a a.c' 'echo $X' 'ls $d' 'git log $x' '$x ls' 'x=$y ls' 'timeout $x 5 ls' '$(which git) status' '${MAKE:-make} all' '"$@"'; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "control passes: $c"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
  run_tables "$c"
  assert_exit "$RC" "0" "passes with no python3"
done

print_summary
teardown_test_env
exit $FAILED
