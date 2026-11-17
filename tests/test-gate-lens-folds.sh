#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: lens rounds 4 and 5: two openers on a line, quoted list argv, the budget on a long command.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

# ── lens round 4 on 9ea6c00: two openers on one line, the body loop's cost, `<` as a prefix ──
test_start "two openers on one line: which body the redirect takes is not traced, so both count (lens 4, B1)"
run_gate "cat <<'A' > notes.md; python3 - <<'B'
bash $CR force-push --marker abc
A
import os; os.system('bash notes.md')
B"
assert_exit "$RC" "2" "the python body on the same opener line counts"
run_gate "python3 - <<'B'; cat <<'A' > notes.md
import os; os.system('bash notes.md')
B
bash $CR force-push --marker abc
A"
assert_exit "$RC" "2" "the openers swapped"
run_gate "cat <<'A' > notes.md; cat <<'B' > other.md
bash $CR force-push --marker abc
A
nothing here names the first
B"
assert_exit "$RC" "0" "control: two notes on one line, neither naming the other, pass"
run_gate "cat <<'A' > notes.md; cat <<'B' > other.md
see notes.md
bash $CR force-push --marker abc
A
text
B"
assert_exit "$RC" "2" "cost, named: a self-naming note sharing its opener line with another heredoc is read"

test_start "a mention bash runs through a redirect or a split quote counts (lens 4, M1)"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 - <<'PY'
import os; os.system('bash<notes.md')
PY"
assert_exit "$RC" "2" "bash<notes.md"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 - <<'PY'
import os; os.system(\"bash n''otes.md\")
PY"
assert_exit "$RC" "2" "n''otes.md"

test_start "more than 32 heredocs is closed unread: the body count is the attacker's path to the 5 s budget (lens 4, B2)"
MANY=""; for i in $(seq 32); do MANY+="cat <<'E$i' >> n$i.md
line
E$i
"; done
run_gate "${MANY}cat <<'E33' >> n33.md
bash $CR force-push --marker abc
E33"
assert_exit "$RC" "2" "the 33rd note, quoting the red line, is read: closed unread"
run_gate "${MANY}cat <<'E33' >> n33.md
line
E33
echo done"
assert_exit "$RC" "0" "control: 33 notes and no red line pass"
MANY=""; for i in $(seq 32); do MANY+="cat <<'E$i' >> n$i.md
bash $CR force-push --marker abc
E$i
"; done
run_gate "${MANY}echo done"
assert_exit "$RC" "0" "control: 32 notes each quoting the red line are 32 notes (and fit the clock)"

test_start "the other-bodies set is the current line's, not the first line's (the mutation that survived)"
# Two doc targets on two lines: the first body names the second file, the second carries the
# red line. On the second line the OTHER body is the first one, which names it: run, closed.
run_gate "cat <<'A' > notes.md
see other.md
A
cat <<'B' > other.md
bash $CR force-push --marker abc
B"
assert_exit "$RC" "2" "the first body names the second file: the second is read"
# And the mirror: a stale set from the first line would hold the SECOND body, whose own
# self-mention would then count against itself.
run_gate "cat <<'A' > notes.md
bash $CR force-push --marker abc
A
cat <<'B' > other.md
see other.md
B"
assert_exit "$RC" "0" "a self-naming second note is still a note when the first names nothing"

# ── lens round 5 on 8bfd395: a quoted list argv, and the budget on a long command ──────
test_start "a mention whose only prefix is a quote survives the unquoting (lens 5, B1)"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 - <<'PY'
import subprocess; subprocess.run([\"bash\",\"notes.md\"])
PY"
assert_exit "$RC" "2" "a python list argv, double quotes"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
python3 - <<'PY'
import os; os.execvp('bash',['bash','notes.md'])
PY"
assert_exit "$RC" "2" "a python list argv, single quotes"

test_start "a command past the line caps is closed unread, within the hook budget (lens 5, B2)"
# The per-line walks (the stripper on every command line, the shell-fed scan on every line
# the stripper hands back) each cost milliseconds a line; a 700-line plain command and a
# 5,000-line heredoc that never closes both outran the 5 s budget, which blocks nothing.
# (the three heredoc lines count: 2,046 + 3 = 2,049 lines, one over the cap)
LONG="$(for i in $(seq 2046); do printf 'echo line %s\n' "$i"; done)"
run_gate "$LONG
cat <<'EOF' >> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "2,049 command lines: the note is read whole (closed), not stripped"
LONG="$(for i in $(seq 300); do printf 'echo line %s\n' "$i"; done)"
run_gate "$LONG
cat <<'EOF' >> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "cost, named: 300 command lines hand back more than the scan cap, so the note is read"
LONG="$(for i in $(seq 200); do printf 'echo line %s\n' "$i"; done)"
run_gate "$LONG
cat <<'EOF' >> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "control: 200 command lines and a note, under both caps, the note is still a note"
LONG="$(for i in $(seq 2046); do printf 'echo line %s\n' "$i"; done)"
_t0="$(t_now_us)"
run_gate "$LONG
bash $CR force-push --marker abc"
_ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "2,046 plain lines then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
# Past the command cap the stripper must not walk at all, and nothing below may walk the
# command for it either (the table and the guards take the one view made here): without
# the cap, or with any of them stripping again, 8,000 lines cost ~0.7 ms each per walk.
LONG="$(for i in $(seq 8000); do printf 'echo line %s\n' "$i"; done)"
_t0="$(t_now_us)"
run_gate "$LONG
bash $CR force-push --marker abc"
_ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "8,000 plain lines then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"

test_start "the walks are bounded by the clock, not by a line count (lens 6 on 8a0de19)"
# The stripper's quote-carrying walk is per character and worse than linear in a line's
# quotes: one 20 KB line of `"a" "a" …` cost it 6.9 s, twelve 3.5 KB ones would cost 8 s,
# and twenty 3.9 KB opener lines cost the opener walk 5 s, every one under both line caps.
QH="$(for i in $(seq 2500); do printf '"a" '; done)"      # ~10 KB of quote pairs
run_timed() { _t0="$(t_now_us)"; run_gate "$1"; _ms=$(( ($(t_now_us) - $_t0) / 1000 )); }
run_timed "echo $QH$QH
bash $CR force-push --marker abc"
assert_exit "$RC" "2" "one 20 KB quote-heavy line then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
Q3="${QH:0:3500}"
run_timed "$(for i in $(seq 12); do printf 'echo %s\n' "$Q3"; done)
bash $CR force-push --marker abc"
assert_exit "$RC" "2" "twelve 3.5 KB quote-heavy lines then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
PAD="$(printf 'x%.0s' $(seq 3900))"
run_timed "$(for i in $(seq 20); do printf "echo %s <<'E%s' >> n%s.md\nbody\nE%s\n" "$PAD" "$i" "$i" "$i"; done)
bash $CR force-push --marker abc"
assert_exit "$RC" "2" "twenty 3.9 KB opener lines then the red line: blocked"
assert_contains "$ERR" "[RED]" "and red (the force-push row, or the clock's own refusal)"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
# The control is two openers, not twenty. Since 2026-11-04 a walk that runs past its
# budget leaves the judge unrun, and that is refused red on a command with no key (a cut
# judge passed `env -C <dir> git push`). The dev box is a container on a shared host, and
# with the host at load 30 the twenty walked for 3 s, the budget itself, and twelve did
# too; the budget is the budget on a slow day, and the named cost is a refusal with "retry".
# The control wants margin from it, not a seat on it; the twenty with the red line block
# above, inside the budget, which is the claim in this test's name. Four openers walked for
# 2.2 s on that day: the opener walk is dear per line, a performance item of its own.
run_timed "$(for i in $(seq 2); do printf "echo %s <<'E%s' >> n%s.md\nbody\nE%s\n" "$PAD" "$i" "$i" "$i"; done)
echo done"
assert_exit "$RC" "0" "control: two of the same, no red line, pass (${_ms} ms)"

test_start "the views expand a tilde where bash does, at a word's start (lens 7, B1)"
# Every `~` was replaced by $HOME, so a line of 4,000 tildes grew by HOME's length before
# every grep, twice, outside the clock: 240 KB of them killed the hook (lens 7 on fc838c1).
# Bash expands only a word-initial `~` (and after `=` or `:`); the views now do the same.
# (built with python: 240 KB is past jq's argv cap, and a harness that never reached the
# gate read as a pass the first time this test ran)
# (30 lines, under the byte cap: the cap would refuse 60 before any view was built. The
# tilde rule itself is pinned in test-_maude-common.sh, on maude_home_view.)
J="$(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":("~"*4000+"\n")*30+"bash /x/hooks/scripts/maude-clear-red.sh force-push --marker abc\n"},"hook_event_name":"PreToolUse"}))')"
_t0="$(t_now_us)"; printf '%s' "$J" | bash "$GATE" >/dev/null 2>&1; RC=$?; _ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "30 lines of 4,000 tildes then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
run_gate "rm -rf ~/.claude"; assert_exit "$RC" "2" "control: a word-initial ~/ still resolves (rm -rf ~/.claude)"
run_gate "echo x > ~/.maude/plugin/care-redclear.json"; assert_exit "$RC" "2" "control: ~/ in a redirect target still resolves"
run_gate "cp x.json ~/.maude/plugin/care-redclear.json"; assert_exit "$RC" "2" "control: ~/ as a later operand still resolves"

test_start "a command past 128 KB is refused whole, before any walk (lens 7, B2)"
# Nothing bounded the total: after the clock stops the walks, the whole-command reads (the
# table, the views, the backstop greps) still cost per byte, and ~1.5 MB of plain lines
# outran the 5 s budget. Past the cap the gate reads nothing and refuses: split it.
BIG="$(head -c 135000 /dev/zero | tr '\0' x | fold -w 80)"
J="$(printf '%s\necho done\n' "$BIG" | python3 -c 'import sys,json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()},"hook_event_name":"PreToolUse"}))')"
_t0="$(t_now_us)"; ERR="$(printf '%s' "$J" | bash "$GATE" 2>&1 >/dev/null)"; RC=$?; _ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "a 135 KB command with no red line: refused"
BIG="$(head -c 120000 /dev/zero | tr '\0' x | fold -w 80)"
J="$(printf '%s\necho done\n' "$BIG" | python3 -c 'import sys,json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()},"hook_event_name":"PreToolUse"}))')"
_t0="$(t_now_us)"; printf '%s' "$J" | bash "$GATE" >/dev/null 2>&1; RC2=$?; _ms2=$(( ($(t_now_us) - $_t0) / 1000 ))
if t_slow_shell; then
  case "$RC2" in 0|2) _pass ;; *) _fail "control: a 120 KB command: rc $RC2, neither a pass nor a refusal" ;; esac
  assert_exit "$([ "$_ms2" -lt 5000 ] && echo 0 || echo 1)" "0" "control: inside the harness's 5 s (${_ms2} ms)"
  t_skip "control: a 120 KB command with no red line passes"
else
  assert_exit "$RC2" "0" "control: a 120 KB command with no red line passes"
fi
case "$ERR" in *split*) _pass ;; *) _fail "the refusal does not say to split it: $ERR" ;; esac
assert_exit "$([ "$_ms" -lt 1000 ] && echo 0 || echo 1)" "0" "and fast (${_ms} ms)"
HM="$(for i in $(seq 1600); do printf '$HOME/x '; done)"
J="$(for i in $(seq 9); do printf 'echo %s\n' "$HM"; done | python3 -c 'import sys,json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()+"bash /x/hooks/scripts/maude-clear-red.sh force-push --marker abc\n"},"hook_event_name":"PreToolUse"}))')"
_t0="$(t_now_us)"; printf '%s' "$J" | bash "$GATE" >/dev/null 2>&1; RC=$?; _ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "just under the cap, every word a \$HOME (the other amplifier), then the red line: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
# (1,200 raw lines: jq's argv cap stops the harness near 128 KB; the hook itself has none)
RAW="$(head -c 96000 /dev/zero | tr '\0' x | fold -w 80)"
_t0="$(t_now_us)"
run_gate "cat <<'EOF' >> notes.md
$RAW
bash $CR force-push --marker abc"
_ms=$(( ($(t_now_us) - $_t0) / 1000 ))
assert_exit "$RC" "2" "a 1,200-line heredoc that never closes is read raw: blocked"
assert_exit "$([ "$_ms" -lt 5000 ] && echo 0 || echo 1)" "0" "and inside the 5 s budget (${_ms} ms)"
run_gate "cat >> now_maude.md <<'EOF'
see now_maude.md for the rest
bash $CR force-push --marker abc
EOF
cat >> now_maude.md <<'EOF'
and now_maude.md again
EOF"
# PINNED COST (pre-existing, found 2026-10-18): the named-again count reads the opener
# mentions too, so two writes to ONE doc in one command count as "named again" and the
# bodies are read; it costs a block only when a body carries the red line. Splitting the
# writers by operand grammar would put the writer list in two places; not done.
assert_exit "$RC" "2" "pinned cost: two appends to the same note in one command, with the red line, close"

test_start "an opener line past 4 KB is closed unread (the hook budget), and one with no red line passes"
LONG="$(printf 'x%.0s' $(seq 4200))"
run_gate "cat <<'EOF' >> notes.md # $LONG
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "closed, not walked"
run_gate "cat <<'EOF' >> notes.md # $LONG
plain prose
EOF"
assert_exit "$RC" "0" "nothing to block"

test_start "control: tee -a notes.md before the heredoc is text"
run_gate "tee -a notes.md <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "passes"

test_start "a script target with a doc-shaped stderr beside it is still a script"
run_gate "cat <<'EOF' > f.sh 2>notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "> f.sh 2>notes.md"
run_gate "cat > f.sh 2>err.txt <<'EOF'
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "2" "> f.sh 2>err.txt"

test_start "control: a body piped to a reader or an interpreter is text"
run_gate "cat <<'EOF' | jq .
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "jq passes"
run_gate "cat <<'EOF' | python3 -
print(\"bash $CR force-push --marker abc\")
EOF"
assert_exit "$RC" "0" "python passes"
run_gate "cat <<'EOF' | tee -a notes.md | grep x
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "tee to a note then grep passes"

test_start "control: a note piped through cat into a .md is text, and so is 2>&1 into a .md"
run_gate "cat <<'EOF' | cat >> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "passes"
run_gate "cat <<'EOF' 2>&1 >> notes.md
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "passes"

test_start "control: a note with stderr to /dev/null is still text"
run_gate "cat <<'EOF' > notes.md 2>/dev/null
bash $CR force-push --marker abc
EOF"
assert_exit "$RC" "0" "passes"

test_start "a doc-shaped file written and then run in the same command keeps its body"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
bash notes.md"
assert_exit "$RC" "2" "blocked"
run_gate "cat <<'EOF' > Makefile.txt
a:
	bash $CR force-push --marker abc
EOF
make -f Makefile.txt"
assert_exit "$RC" "2" "blocked"

test_start "the opener need not be the first line: a later heredoc's doc-shaped file run afterwards keeps its body"
run_gate "echo start
cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
bash notes.md"
assert_exit "$RC" "2" "blocked"

test_start "control: a doc-shaped file written and then merely mentioned in prose passes"
run_gate "cat <<'EOF' > notes.md
bash $CR force-push --marker abc
EOF
echo wrote the notes"
assert_exit "$RC" "0" "passes"

print_summary
teardown_test_env
exit $FAILED
