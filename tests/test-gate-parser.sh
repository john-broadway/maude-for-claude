#!/usr/bin/env bash
# Tests for the shell parser's read in hooks/scripts/maude-gate.sh (maude_shell/judge.py).
#
# The parser runs beside the regex tables and can only ADD a block. These tests hold the
# three halves of that: what it now catches (tier B of docs/gate-threat-model.md, and the
# plain forms the tables missed), what it must still pass (a mention is not a command),
# and that a parser that is absent, slow or planted-over changes nothing. The judge's own
# rules are tested word by word in tests/shell/test_judge.py; this file is the hook.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

GATE="$HOOKS_DIR/maude-gate.sh"

run_gate() {
  ERR="$(make_bash_tool_input "$1" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

# ── what the tables missed and the parser reads ─────────────────────────────
for c in '"git" push' '\git push' '{git,push}' 'git pu{sh,}' 'time git push' 'nice -n 5 git push' \
         'if true; then git push; fi' '{ git push; }' 'for x in a; do git push; done' \
         'timeout -s KILL 5m git push' 'xargs -n 1 git push' 'env -u HOME X=1 git push' \
         'eval git push' "bash <<< 'git push'" "echo 'git push' | sh" 'bash <<EOF
git push origin main
EOF'; do
  test_start "parser blocks: $(printf '%s' "$c" | tr '\n' '|')"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "git push detected" "with the git-push message"
  if [ "$c" = "echo 'git push' | sh" ]; then
    # an echo into a shell is never read whole (bfebd78): the token check speaks instead
    assert_contains "$ERR" "could not read all of this command" "and says it could not read it all"
  else
    assert_contains "$ERR" "read through the shell parser as: git push" "and says what it read"
  fi
done

test_start "parser blocks a dressed force-push as force-push, a RED key"
run_gate 'sudo -u root "git" push --force'
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "[RED]" "red tier"
assert_contains "$ERR" '"force-push" is a RED key' "keyed force-push"

test_start "parser blocks a dressed rm -rf / as rm-rf-root"
for c in "'rm' -rf /" 'r\m -rf /' "\$'rm' -rf /" 'rm -rf /*'; do
  run_gate "$c"
  assert_exit "$RC" "2" "$c"
  assert_contains "$ERR" '"rm-rf-root" is a RED key' "$c keyed rm-rf-root"
done

test_start "parser blocks rm -rf of home: it holds ~/.claude, a sole copy"
for c in 'rm -rf ~' 'rm -rf "${HOME}"' 'rm -rf $HOME'; do
  run_gate "$c"
  assert_exit "$RC" "2" "$c"
  assert_contains "$ERR" "rm-rf-sole-copy" "$c keyed rm-rf-sole-copy"
done
run_gate 'rm -rf ~/*'
assert_contains "$ERR" "rm-rf-glob" "a glob at the root of home is rm-rf-glob"

test_start "parser reads past a payload the wrapped walk cannot: bash -c \"\$x\"; \\rm -rf /"
run_gate 'bash -c "$x"; \rm -rf /'
assert_exit "$RC" "2" "the readable half still blocks"

test_start "a parser block writes a trace row naming its key"
: > "$(trace_path)"
run_gate '"git" push'
n="$(count_trace_lines '.kind == "gate" and (.note // .detail // "" | tostring | test("parser=git-push"))')"
[ "$n" -gt 0 ] || n="$(grep -c 'parser=git-push' "$(trace_path)" 2>/dev/null)"
[ "$n" -gt 0 ]
assert_exit "$?" "0" "trace row parser=git-push"

# ── mentions and run-time values pass ───────────────────────────────────────
for c in 'echo "git push --force"' 'git commit -m "never rm -rf /"' "printf '%s\n' 'git reset --hard'" \
         'cat <<EOF > note.md
git push --force
EOF' "grep -r 'git push' ." 'rm -rf $x' 'bash -c "$x"' 'command -v git' \
         'rm -rf build/*' 'git status' 'g{it,} status'; do
  test_start "parser passes: $(printf '%s' "$c" | tr '\n' '|')"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done

# ── absent, slow, or planted over: the regex verdict stands ─────────────────
test_start "no python3: the parser is skipped, the tables still block their own"
NOPY="$(make_no_binary_bin python3)"
ERR="$(make_bash_tool_input '"git" push' | PATH="$NOPY" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "tier B is the parser's: passes without it"
ERR="$(make_bash_tool_input 'git push' | PATH="$NOPY" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "tier A plain push still blocks on the tables"

test_start "a parser that hangs is cut at its 2 s, and the cut refuses what the tables did not key"
# Until 2026-11-04 this test pinned the opposite ("the cut read changes nothing", rc 0): a
# quoted `"git" push`, keyed by the judge alone, passed whenever the judge hung. The cut now
# reads red (parser-budget) on a command with no key, inside the same time.
SLOW="$(make_no_binary_bin python3)"
REALPY="$(command -v python3)"
cat > "$SLOW/python3" <<EOF
#!/usr/bin/env bash
# The judge's call carries its code after -c; only that one hangs.
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-c" ]; then case "\$a" in *maude_shell.judge*) sleep 20; exit 0 ;; esac; fi
  prev="\$a"
done
exec "$REALPY" "\$@"
EOF
chmod +x "$SLOW/python3"
t0="$SECONDS"
ERR="$(make_bash_tool_input '"git" push' | PATH="$SLOW" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
el=$((SECONDS - t0))
assert_exit "$RC" "2" "the cut read refuses the command"
assert_contains "$ERR" "shell parser did not finish" "names the cut"
[ "$el" -le 4 ]
assert_exit "$?" "0" "the gate finished in ${el}s, inside its 5 s budget"

# ── a yellow key never hides a red one (the commit security review on 965d025) ──
# The gate keyed a command by its FIRST match, and a token is per key. So a command that
# held a yellow key and a red one, keyed yellow, passed whole on a yellow token, which
# Claude may mint: the red half ran on a self-clear. Every stage now runs until the key
# is red, and only a red key replaces a yellow one. Each case carries a live git-push
# token: the block must name the red key and leave the yellow token unreserved.
test_start "a live yellow token never opens the red half of the same command"
while IFS='|' read -r want c; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  c="${c//@P@/$CLAUDE_PROJECT_DIR}"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked: $c"
  assert_contains "$ERR" "[RED]" "red tier: $c"
  assert_contains "$ERR" "$want" "keyed red: $c"
  assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved: $c"
done <<'EOF'
rm-rf-root|git push; \rm -rf /
rm-rf-sole-copy|git push; "rm" -rf ~
force-push|git push; git push origin +main
force-push|git push; "git" push -f
sole-copy-target|git push && bash -c 'mv @P@ /tmp/x'
"force-push" is a RED key|git push && bash hooks/scripts/maude-clear-gate.sh force-push
red-clear token file|git push; echo x > @P@/.maude/plugin/care-redclear.json
rm-rf-root|"git" push; eval 'rm -rf /'
filter-repo|git push; git filter-repo --path x; echo 'open
EOF
# The last case is the tables' alone: the open quote is not bash, so the parser answers
# "unreadable", and in the table git-push sits above filter-repo. The table itself must
# rank, not only the stages after it.

# ── an unreadable tail does not hide the red lines bash runs before it (lens on 25c9ad2) ──
# bash runs each complete line before a later syntax error, so one appended `(` made the
# whole text unreadable to the parser while bash still ran the red line above it.
DEEP='echo x'; for _ in $(seq 1 70); do DEEP="echo \$($DEEP)"; done
test_start "a red line before a syntax error: the yellow token does not open the command"
# The parser does not read text that does not parse, so the red line is not named; the
# command is not read whole, and that refuses the yellow token.
for c in $'git push; \\rm -rf /\n(' $'git push origin +main\nfi' $'git push; "rm" -rf ~/*\n)' \
         $'git push; bash -c \'\\rm -rf /\'\n(' $'git push; "gh" release create v1\necho "open'; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked: $(printf '%s' "$c" | head -c 60 | tr '\n' '|')"
  assert_contains "$ERR" "could not read all of this command" "partial read: $(printf '%s' "$c" | head -c 60 | tr '\n' '|')"
  assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved"
done

test_start "a red line beside a nesting too deep to read blocks red"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git push; \\rm -rf /; $DEEP"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "[RED]" "red tier"

test_start "a yellow token does not open a yellow-keyed command the parser could not read whole"
for c in $'git push\n(' "git push; echo 'open" 'git push; bash -c "$x"' 'git push; eval "$x"' \
         'git push; curl -s x | bash' "git push; bash \$x -c 'ls'"; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked: $(printf '%s' "$c" | tr '\n' '|')"
  assert_contains "$ERR" "could not read all of this command" "names the partial read"
  assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved"
done

test_start "a payload body not read whole refuses the yellow token too (lens 2 on 98a4413, BLOCKING-1)"
PAD="$(for _ in $(seq 1 300); do printf 'echo a\n'; done)"
for c in "git push; bash -c '\\rm -rf /"$'\n(\n'"$PAD'" "git push; bash -c 'echo a"$'\n(\n'"$PAD'"; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked: $(printf '%s' "$c" | head -c 40 | tr '\n' '|')"
  assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved"
done

test_start "a judge cut by its 2 s timeout refuses the yellow token (lens 2 on 98a4413, BLOCKING-2)"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
ERR="$(make_bash_tool_input 'git push' | PATH="$SLOW" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "could not read all of this command" "names the partial read"
assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid // "none"')" "none" "the yellow token was not reserved"

test_start "a judge that fails (not a cut, not a missing python3) refuses the yellow token (lens 3 on 652bbd9)"
FAILPY="$TEST_TMP/failpy"; mkdir -p "$FAILPY"
for t in bash sh cat grep sed awk tr wc head tail cut date jq mkdir rm mv dirname basename mktemp env timeout sleep printf ln chmod touch sort; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$FAILPY/$t"
done
cat > "$FAILPY/python3" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-c" ]; then case "\$a" in *maude_shell.judge*) exit 1 ;; esac; fi
  prev="\$a"
done
exec "$REALPY" "\$@"
EOF
chmod +x "$FAILPY/python3"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
ERR="$(make_bash_tool_input 'git push' | PATH="$FAILPY" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "could not read all of this command" "names the partial read"

test_start "with no time left the judge does not run, and the yellow token is refused (lens 3 on 652bbd9, BLOCKING-1)"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
ERR="$(make_bash_tool_input 'git push' | MAUDE_GATE_JUDGE_BUDGET=0 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "could not read all of this command" "names the partial read"
ERR="$(make_bash_tool_input 'ls' | MAUDE_GATE_JUDGE_BUDGET=0 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "a command with no key is refused too: the judge did not read it (2026-11-04; it passed before)"
assert_contains "$ERR" "[RED]" "red"
assert_contains "$ERR" "shell parser did not finish" "names the cut"

test_start "a command the judge alone would key does not pass on a judge the clock cut (2026-11-04)"
# `env -C <dir> git push` is read by the shell parser, not the tables: with the judge skipped
# for want of time it passed, rc 0, as it did under a loaded suite. A fail-closed rule ends
# what more parsing cannot.
ERR="$(make_bash_tool_input 'env -C /tmp git push origin main' | MAUDE_GATE_JUDGE_BUDGET=0 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked with the judge skipped"
assert_contains "$ERR" "[RED]" "red"
# The judge itself cut by its clock, not skipped: a stub timeout answers 124 for python3.
CUTJ="$TEST_TMP/cutjudge"; mkdir -p "$CUTJ"
cat > "$CUTJ/timeout" <<EOF
#!/usr/bin/env bash
[ "\$2" = "python3" ] && exit 124
exec "$(t_timeout_bin)" "\$@"
EOF
chmod +x "$CUTJ/timeout"
ERR="$(make_bash_tool_input 'env -C /tmp git push origin main' | PATH="$CUTJ:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked with the judge cut"
assert_contains "$ERR" "shell parser did not finish" "names the cut"
# The spend run never blocks, cut or not.
ERR="$(make_bash_tool_input 'ls' | MAUDE_GATE_JUDGE_BUDGET=0 bash "$GATE" consume 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "the spend run passes"
# A judge that cannot start is the soft dependency it always was: the tables' verdict stands.
NOPY="$TEST_TMP/nopy"; mkdir -p "$NOPY"; printf '#!/bin/sh\nexit 127\n' > "$NOPY/python3"; chmod +x "$NOPY/python3"
ERR="$(make_bash_tool_input 'ls' | PATH="$NOPY:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "no python3: ls passes"
# …and a keyed push on its token too: the judge's absence refuses nothing (the lens on
# c898dca, m2: the no-key half had a pin, this half had none).
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
ERR="$(make_bash_tool_input 'git push' | PATH="$NOPY:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "no python3: a keyed push passes on its token"
rm -f "$(care_path)"
# The budget knob is whole seconds; anything else is the default, never 0 and never an error.
ERR="$(make_bash_tool_input 'ls' | MAUDE_GATE_JUDGE_BUDGET=abc bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "MAUDE_GATE_JUDGE_BUDGET=abc: the default, ls passes"
ERR="$(make_bash_tool_input 'ls' | MAUDE_GATE_JUDGE_BUDGET=1.5 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "MAUDE_GATE_JUDGE_BUDGET=1.5: the default, ls passes"
assert_not_contains "$ERR" "arithmetic" "and no arithmetic error on stderr"
# A python3 that is there but broken (exits 1, no output) is the same soft dependency.
printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"
ERR="$(make_bash_tool_input 'ls' | PATH="$NOPY:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "a broken python3: ls passes"
# A judge that STARTED reading and died is not: its first line is on stdout, and what it
# did not finish is refused (a crash on crafted text, a kill under load).
printf '#!/bin/sh\n[ -n "$MAUDE_JUDGE_MARK" ] && echo read\nexit 1\n' > "$NOPY/python3"
ERR="$(make_bash_tool_input 'env -C /tmp git push origin main' | PATH="$NOPY:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "a judge that started and died: blocked"
assert_contains "$ERR" "shell parser did not finish" "names the unfinished read"
ERR="$(make_bash_tool_input 'ls' | PATH="$NOPY:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "and a plain command too: the gate cannot tell them apart without the judge"

test_start "the judge is given only the time the hook has left"
TOBIN="$TEST_TMP/tobin"; mkdir -p "$TOBIN"; TOLOG="$TEST_TMP/timeout-args"
REALTO="$(t_timeout_bin)"
cat > "$TOBIN/timeout" <<EOF
#!/usr/bin/env bash
[ "\$2" = "python3" ] && printf '%s\n' "\$1" >> "$TOLOG"
exec "$REALTO" "\$@"
EOF
chmod +x "$TOBIN/timeout"
rm -f "$TOLOG"
make_bash_tool_input '"git" push' | PATH="$TOBIN:$PATH" MAUDE_GATE_JUDGE_BUDGET=1 bash "$GATE" >/dev/null 2>&1
assert_ne "$(cat "$TOLOG" 2>/dev/null)" "2" "with 1 s of budget the judge was not handed its full 2 s"
rm -f "$TOLOG"
make_bash_tool_input '"git" push' | PATH="$TOBIN:$PATH" bash "$GATE" >/dev/null 2>&1
assert_eq "$(cat "$TOLOG" 2>/dev/null)" "2" "with time to spare it gets 2 s"

test_start "a yellow command padded with a hundred payloads blocks inside the hook's time (lens 4 on 13c95f8, BLOCKING)"
PADDED="git push origin main"; for i in $(seq 0 99); do PADDED="$PADDED; bash -c 'echo a$i'"; done
rm -f "$(care_path)" "$(redclear_path)"
t0="$SECONDS"; run_gate "$PADDED"; el=$((SECONDS - t0))
assert_exit "$RC" "2" "blocked with no token"
assert_contains "$ERR" "git push detected" "keyed git-push"
[ "$el" -le 4 ]
assert_exit "$?" "0" "the gate finished in ${el}s, inside its 5 s"

test_start "a wrapped walk stopped by its clock refuses the yellow token (lens 4 on 13c95f8, BLOCKING)"
# A stub timeout holds the judge 3 s, so the walk starts overdue and reads nothing.
SLOWJ="$TEST_TMP/slowjudge"; mkdir -p "$SLOWJ"
cat > "$SLOWJ/timeout" <<EOF
#!/usr/bin/env bash
[ "\$2" = "python3" ] && sleep 3
exec "$REALTO" "\$@"
EOF
chmod +x "$SLOWJ/timeout"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
ERR="$(make_bash_tool_input "git push; bash -c 'echo hi'" | PATH="$SLOWJ:$PATH" MAUDE_GATE_JUDGE_BUDGET=9 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "could not read all of this command" "names the partial read"

test_start "a shell's -s and +X options do not hide its stdin behind a live yellow token (lens 4 on 13c95f8, MAJOR)"
for c in "git push; bash -s foo <<'E'"$'\n'"\\rm -rf /"$'\n'"E" "git push; bash +e <<< '\\rm -rf /'" \
         "git push; echo '\\rm -rf /' | bash -s foo"; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked: $(printf '%s' "$c" | tr '\n' '|')"
  assert_contains "$ERR" "[RED]" "red tier: $(printf '%s' "$c" | tr '\n' '|')"
done
for c in 'git push; curl -s x | bash -s foo' 'git push; bash <> /tmp/x.sh'; do
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "not read whole, refused: $c"
done

test_start "a long tail after a syntax error stays inside the hook's time"
LONG="git push"$'\n(\n'"$(for _ in $(seq 1 2000); do printf 'echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; done)"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
t0="$SECONDS"; run_gate "$LONG"; el=$((SECONDS - t0))
assert_exit "$RC" "2" "blocked as a partial read"
assert_contains "$ERR" "could not read all of this command" "by the judge, not by the cut alone"
[ "$el" -le 3 ]
assert_exit "$?" "0" "the gate finished in ${el}s"

# ── The padding bypass (lens 2 on the redclear port, measured on main 26fc003) ────────
# 100,000 spaces before `git push` ran the hook to 7.4 s on this box, 100,000 spaces then
# `;` to 8.3 s, 60,000 words then `;` to 6.9 s, 131,000 `;` to 4.0 s: all under the 128 KB
# cap, all past the harness's 5 s kill, after which a killed hook blocks nothing. One bash
# builtin (`${seg//[[:space:]]/}` over a 100 KB segment) was 5.7 of the 7.4 s. The gate
# is run under a kill one second tighter than the harness's: 124 is the bypass, 2 is the
# block, and the second is margin for a slower CI leg (this box: 0.3 to 3.0 s a shape; the
# slowest is the 40,000-segment one, which the clock cuts as parser-budget).
test_start "a gated command behind padding under the byte cap blocks inside the harness's 5 s"
REALTO="$(t_timeout_bin)"
# The tildes shape (the lens on 177319d, BLOCKING): `~` is one byte in the command and the
# home directory's length in every expanded view, so 62,000 of them stayed under the byte
# cap and made 600 KB of views; the cap now bounds the expanded view too. The near shape
# expands to just under the cap and must still be READ, keyed git-push.
# The fold shape (the advisor on this branch): the red-clear fold substitutes a literal
# value into every use, bounded per word, so a 4 KB value used 25,000 times folded to
# 100 MB under the cap; the folded view is now bounded as a whole (OVER past twice the
# cap), which refuses with the token-file rule's line.
# The assigns shapes (the lens on c898dca, BLOCKING; pre-existing on main): 20,000 `a=1;`
# on one line, or on lines, then a push only the judge reads. A run in a pattern row that
# could cross a `;` scanned to the next space from every start, and the git-push row's one
# grep ran 45 s, which no clock between patterns can cut; every run now stops at `;&|`.
for shape in spaces spaces-semi words-semi semis tabs-semi segments tildes tildes-near fold assigns assigns-lines assign-closet; do
  case "$shape" in
    assigns)       PAD="$(printf 'a=1;%.0s' $(seq 20000))"$'\n''env -C /tmp ' ;;
    assigns-lines) PAD="$(printf 'a=1\n%.0s' $(seq 20000))"$'\n''env -C /tmp ' ;;   # $( ) eats the last newline
    spaces)      PAD="$(printf '%*s' 100000 '')" ;;
    spaces-semi) PAD="$(printf '%*s' 100000 ''); " ;;
    words-semi)  PAD="$(printf 'a %.0s' $(seq 60000)); " ;;
    semis)       PAD="$(head -c 130000 /dev/zero | tr '\0' ';')" ;;
    tabs-semi)   PAD="$(head -c 100000 /dev/zero | tr '\0' '\t'); " ;;
    segments)    PAD="$(printf 'ls;%.0s' $(seq 40000))" ;;
    tildes)      PAD="$(printf '~ %.0s' $(seq 62000)); " ;;
    tildes-near) PAD="$(printf '~ %.0s' $(seq $(( 120000 / (${#HOME} + 2) )))); " ;;
    fold)        PAD="p=$(head -c 4000 /dev/zero | tr '\0' a); $(printf '\$p %.0s' $(seq 25000)); " ;;
    # the fifth lens on the v0.36.0 release: one assignment, 60,000 words and the closet
    # directory spelled run every fold pass; under BSD awk it was killed at 4 s
    assign-closet) PAD="p=1 $(printf 'a %.0s' $(seq 60000)).ma""ude; " ;;
  esac
  rm -f "$(care_path)" "$(redclear_path)"
  _t0="$(t_now_us)"
  ERR="$(make_bash_tool_input "${PAD}git push origin main" | "$REALTO" 4 bash "$GATE" 2>&1 >/dev/null)"; RC=$?
  _ms=$(( ($(t_now_us) - $_t0) / 1000 ))
  assert_exit "$RC" "2" "$shape: blocked, not killed (rc $RC, ${_ms} ms)"
  case "$shape" in
    tildes) assert_contains "$ERR" "expands to" "tildes: refused whole by the expanded cap" ;;
    fold)   assert_contains "$ERR" "[RED]" "fold: refused by the fold's bound" ;;
    *) case "$ERR" in *"git push detected"*|*"ran out of time"*) _pass ;; *) _fail "$shape: refused by neither the key nor the clock: $ERR" ;; esac ;;
  esac
done
rm -f "$(care_path)" "$(redclear_path)"
make_bash_tool_input "$(printf '%*s' 100000 '')ls" | "$REALTO" 4 bash "$GATE" >/dev/null 2>&1; RC=$?
assert_exit "$RC" "0" "control: a padded command with no key passes"

test_start "a run of 64 or more blanks reads as one before any view (the reservation's head shows it)"
# Every view of the command walks its bytes, so the squeeze comes before them all. The
# command runs as sent; only the gate's view changes. The reservation's head is the first
# 60 characters of that view: 63 blanks keep it blank, 64 make it the command.
for pair in "63|$(printf '%*s' 63 '')|$(printf '%*s' 60 '')" \
            "64|$(printf '%*s' 64 '')| git push origin main" \
            "tabs|$(head -c 100 /dev/zero | tr '\0' '\t')|$(printf '\t')git push origin main"; do
  n="${pair%%|*}"; rest="${pair#*|}"; pad="${rest%%|*}"; want="${rest#*|}"
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
  make_bash_tool_input "${pad}git push origin main" | bash "$GATE" >/dev/null 2>&1; RC=$?
  assert_exit "$RC" "0" "$n blanks: passes on its yellow token"
  assert_eq "$(jq -r '.gate_cleared["git-push"].reserved.head' "$(care_path)")" "$want" "$n blanks: the head is the view"
done
# One class at a time (the security review on this branch): `<<-` strips leading tabs
# only, so a tab then 64 spaces before the delimiter word is body text to bash; squeezed
# to a lone tab it would close the body for the gate and read the body's next line as a
# command. The gate and bash must agree on where the body ends.
TAB="$(printf '\t')"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "cat <<-'EOF' > notes.md
${TAB}$(printf '%*s' 64 '')EOF
git push origin main
EOF"
assert_exit "$RC" "0" "a tab then 64 spaces before the word is not the delimiter: the push is body text, as bash reads it"
run_gate "cat <<-'EOF' > notes.md
$(head -c 64 /dev/zero | tr '\0' '\t')EOF
git push origin main
EOF"
assert_exit "$RC" "2" "control: 64 tabs before the word IS the delimiter to bash, and to the gate: the push is a command"
# A quoted delimiter holding a blank run: the squeeze is run-local and stops at a quote,
# so a closing line equal to the delimiter byte for byte squeezes equal, and bash closing
# the body means the gate closes it. Spelled with a different count above 64 the gate
# closes early where bash does not: a block, never a pass (the cost, named in CHANGELOG).
SP64="$(printf '%*s' 64 '')"
run_gate "cat <<'E${SP64}F' > notes.md
E${SP64}F
git push origin main
E${SP64}F"
assert_exit "$RC" "2" "a delimiter with 64 spaces closes on the line that spells it: the push is a command to bash and to the gate"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "cat <<'E${SP64}F' > notes.md
E${SP64} F
git push origin main
E${SP64}F"
assert_exit "$RC" "2" "pinned cost: a closing line with 65 spaces is body to bash; the gate closes early and blocks the push, never passes it"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
make_bash_tool_input "$(printf '%s' "${TAB} " | awk '{ for (i = 0; i < 50; i++) printf "%s", $0 }')git push origin main" | bash "$GATE" >/dev/null 2>&1; RC=$?
assert_exit "$RC" "0" "a mixed run passes on its yellow token"
assert_eq "$(jq -r '.gate_cleared["git-push"].reserved.head' "$(care_path)" | head -c 4)" "${TAB} ${TAB} " "control: a mixed run of tabs and spaces is not squeezed across its kinds"

test_start "the pattern walk cut by its clock refuses red as parser-budget, which nothing clears"
# A grep on PATH holds the first table grep past the walks' 3 s; the clock between the
# patterns fires before the next one, and the tables were not read whole: red, like
# parser-depth, read from the red file only.
SLOWG="$TEST_TMP/slowgrep"; mkdir -p "$SLOWG"; REALGREP="$(command -v grep)"
cat > "$SLOWG/grep" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-qE" ] && [ ! -e "$TEST_TMP/slowgrep.once" ]; then : > "$TEST_TMP/slowgrep.once"; sleep 3; fi
exec "$REALGREP" "\$@"
EOF
chmod +x "$SLOWG/grep"
rm -f "$(care_path)" "$(redclear_path)" "$TEST_TMP/slowgrep.once"
ERR="$(make_bash_tool_input 'git push origin main' | PATH="$SLOWG:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "[RED]" "red tier"
assert_contains "$ERR" "ran out of time" "keyed parser-budget"
printf '{"gate_cleared":{"parser-budget":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
rm -f "$TEST_TMP/slowgrep.once"
ERR="$(make_bash_tool_input 'git push origin main' | PATH="$SLOWG:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "a parser-budget token in care.json does not open it"
assert_contains "$ERR" "care-redclear.json)" "looked in the red file"
: > "$TEST_TMP/slowgrep.once"
rm -f "$(care_path)" "$(redclear_path)"
ERR="$(make_bash_tool_input 'git push origin main' | PATH="$SLOWG:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "control: the same stub with its sleep spent still blocks"
assert_contains "$ERR" "git push detected" "control: an uncut walk keys git-push"

test_start "a split held past the clock cuts the walk before its first pattern"
# The plain-command check reads every segment's command word; a tr on PATH holds the
# split 3 s, and the first clock asked after it (the segment loop's, every 64 segments,
# or the pattern loop's) refuses. The in-loop check itself is pinned by the 40,000-segment
# shape above, whose walk alone outruns the kill on a loaded box.
SLOWT="$TEST_TMP/slowtr"; mkdir -p "$SLOWT"; REALTR="$(command -v tr)"
cat > "$SLOWT/tr" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-s" ] && [ "\$2" = ";&|" ] && [ ! -e "$TEST_TMP/slowtr.once" ]; then : > "$TEST_TMP/slowtr.once"; sleep 3; fi
exec "$REALTR" "\$@"
EOF
chmod +x "$SLOWT/tr"
MANY="$(printf 'ls;%.0s' $(seq 100))git push origin main"
rm -f "$(care_path)" "$(redclear_path)" "$TEST_TMP/slowtr.once"
ERR="$(make_bash_tool_input "$MANY" | PATH="$SLOWT:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "ran out of time" "keyed parser-budget by the segment walk"
: > "$TEST_TMP/slowtr.once"
rm -f "$(care_path)" "$(redclear_path)"
ERR="$(make_bash_tool_input "$MANY" | PATH="$SLOWT:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_contains "$ERR" "git push detected" "control: the uncut walk keys git-push"

test_start "a command too deep to read blocks as parser-depth, red, even with no other key"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "$DEEP"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "[RED]" "red tier"
assert_contains "$ERR" "nests deeper than the shell parser reads" "keyed parser-depth"

test_start "unreadable text with no key is refused (parser-unread; the lens on c898dca, M4)"
# Until 2026-11-04 this pinned the pass: "unreadable" refused a yellow token and nothing
# else, so one line the judge cannot read ahead of a key only the judge reads passed, and
# bash ran it (`shopt -s extglob` / `ls !(x)` / `env -C /tmp git push --force`).
run_gate "echo 'open"
assert_exit "$RC" "2" "a stray quote: refused"
assert_contains "$ERR" "[RED]" "red"
assert_contains "$ERR" "could not read all of this command" "names the unread part"
run_gate $'shopt -s extglob\nls !(x) >/dev/null 2>&1\nenv -C /tmp git push --force origin main'
assert_exit "$RC" "2" "an unread line ahead of a judge-only force-push: refused"
assert_contains "$ERR" "[RED]" "red"
run_gate $'shopt -s extglob\nls !(x) >/dev/null 2>&1\necho done'
assert_exit "$RC" "2" "the same with nothing gated behind it: refused too, the cost named"
# …and one level down, in a literal payload (the commit review on 2178e43): the tables
# read the literal text and do not key `env -C`; the judge's parse failure there is the
# command's.
run_gate "bash -c \$'shopt -s extglob\\nls !(x) >/dev/null 2>&1\\nenv -C /tmp git push --force origin main'"
assert_exit "$RC" "2" "an unread line inside a literal payload: refused"
assert_contains "$ERR" "[RED]" "red"
run_gate 'eval "$x"'
assert_exit "$RC" "0" "a run-time payload is opaque, not unread: whispered and passed, as before"
assert_contains "$ERR" "can't inspect" "the whisper"
# The spend run never blocks.
ERR="$(make_bash_tool_input "echo 'open" | bash "$GATE" consume 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "the spend run passes"

test_start "a token for a key that ranks red is never read from care.json (lens on 25c9ad2, MAJOR-1)"
for pair in "red-self-clear|bash hooks/scripts/maude-clear-gate.sh force-push" \
            "redclear-write|echo x > $CLAUDE_PROJECT_DIR/.maude/plugin/care-redclear.json" \
            "parser-depth|$DEEP"; do
  k="${pair%%|*}"; c="${pair#*|}"
  rm -f "$(care_path)" "$(redclear_path)"
  printf '{"gate_cleared":{"%s":{"until":%d}}}\n' "$k" $(($(date +%s) + 600)) > "$(care_path)"
  run_gate "$c"
  assert_exit "$RC" "2" "$k token in care.json does not open: $c"
  assert_contains "$ERR" "care-redclear.json)" "looked in the red file for $k"
done

test_start "a command of yellow keys only still passes on its yellow token"
rm -f "$(care_path)" "$(redclear_path)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate 'git status; git push'
assert_exit "$RC" "0" "a yellow-only command keeps its yellow key"

test_start "a stdlib name planted in the working directory does not run inside the gate"
PLANT="$TEST_TMP/plant"; mkdir -p "$PLANT"
SENT="$TEST_TMP/plant-ran"
# re is the parser's first stdlib import that the interpreter has not already loaded
cat > "$PLANT/re.py" <<EOF
open("$SENT", "w").write("ran")
raise SystemExit("planted")
EOF
rm -f "$SENT"
ERR="$( cd "$PLANT" && make_bash_tool_input '"git" push' | PYTHONPATH="$PLANT" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_file_absent "$SENT" "the planted re.py never ran"
assert_exit "$RC" "2" "the plugin's parser answered and blocked"

# ── the judge fuzzer's finds, through the real hook (tests/shell/test_judge_fuzz.py) ──
for c in 'env -u HOME rm -rf ~' 'env -u HOME rm -rf ${HOME}' "sudo -u root echo 'rm -rf /' | sh" \
         "ionice -c 3 echo 'git push -f origin main' | sh" "busybox echo 'git filter-repo --force' | sh"; do
  test_start "hook blocks a fuzzer find RED: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "[RED]" "red tier"
done

# ── the bypass list (feat/gate-bypasses): each passed the live hook before ──
for c in "echo 'rm -rf /' | bash /dev/stdin" "bash <(echo 'rm -rf /')" "sh < <(echo 'rm -rf /')" \
         "echo 'rm -rf /' |& bash" "yes 'rm -rf /' | head -1 | sh" "echo 'rm -rf /' | cat | sh" \
         "echo 'rm -rf /' | xargs -0 sh -c" "source <(echo 'git push --force')" \
         "{ echo 'rm -rf /'; } | sh" "su -c 'rm -rf /' root" "script -qc 'rm -rf /' /dev/null" \
         "find / -exec rm -rf {} \\;" "git -c alias.p='push --force' p" "trap 'rm -rf /' EXIT" \
         "strace -f rm -rf /" "chroot / rm -rf /" "ssh host rm -rf /"; do
  test_start "hook blocks a bypass-list form RED: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"
  assert_contains "$ERR" "[RED]" "red tier"
done

test_start "a gated verb on line 1 followed by thousands of lines is still read (a peer's SIGPIPE class, 2026-11-04)"
# grep -q exits on its first matching line; past the pipe's 64 KB the writer takes SIGPIPE,
# and under pipefail the pipeline reads "no match" (two workspace hooks fell that way on
# 2026-11-04). The gate runs without pipefail, and a mutant with it set still blocked every
# key here: the block decisions do not ride on a writer's status. What that mutant lost was
# the opaque-wrap whisper (maude_has_opaque_wrap is such a pipeline), so the whisper is
# pinned too. 12,000 lines is 84 KB: inside the pipe's window, under the gate's cap.
LINES="$(yes 'echo x' | head -n 12000)"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "git push origin main"$'\n'"$LINES"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "git push detected" "keyed git-push"
run_gate "bash -c '\\rm -rf /'"$'\n'"$LINES"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "[RED]" "red"
run_gate 'eval "$x"'$'\n'"$LINES"
assert_exit "$RC" "0" "an opaque wrap passes, whispered"
assert_contains "$ERR" "can't inspect" "the whisper survives the long input"
# 12,000 lines is past MAUDE_GATE_CMD_LINES_CAP (2,048), where the stripper is skipped; the
# same pin under the line cap: 2,000 lines of 41 bytes, 82 KB, past the pipe's 64 KB.
LINES2="$(yes 'echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | head -n 2000)"
run_gate "git push origin main"$'\n'"$LINES2"
assert_exit "$RC" "2" "blocked under the line cap"
assert_contains "$ERR" "git push detected" "keyed git-push"
run_gate 'eval "$x"'$'\n'"$LINES2"
assert_exit "$RC" "0" "an opaque wrap passes under the line cap"
assert_contains "$ERR" "can't inspect" "whispered"

test_start "hook blocks a payload nested past the reader's cap"
c='git status'
for _ in 1 2 3 4; do c="bash -c $(printf '%q' "$c")"; done
run_gate "$c"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "nests deeper than the shell parser reads" "keyed parser-depth"

print_summary
teardown_test_env
exit $FAILED
