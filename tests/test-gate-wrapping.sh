#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: shell-wrapping inspection and the shell-fed heredoc decision.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

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

# ── A RED refusal says its tier first and names whose hand it is; a yellow one names the
# self-clear (the UX lens, 2026-09-06, D2 and D3: six of nine refusals told the person
# to run the yellow self-clear for a red key, and nothing but a path in a parenthetical
# told a red refusal from a yellow one). A pass on a live token says so (N4).
test_start "a RED-key refusal opens with the tier and never tells the person to run the yellow self-clear"
run_gate "git push --force origin main"
assert_exit "$RC" "2" "blocked"
assert_contains "$ERR" "Maude [RED]:" "the tier is the first token"
assert_not_contains "$ERR" "Run /maude:conscience" "no self-clear instruction for a red key"
assert_contains "$ERR" "/maude:conscience force-push" "the command that shows the line to paste is still named"
assert_contains "$ERR" "hand" "whose hand it is"

test_start "a yellow refusal keeps its shape: no tier tag, the self-clear named"
run_gate "git push origin main"
assert_exit "$RC" "2" "blocked"
assert_not_contains "$ERR" "[RED]" "yellow is not tagged red"
assert_contains "$ERR" "Run /maude:conscience git-push" "the self-clear is named"

test_start "every red row carries the tag from the one place that prints refusals"
run_gate 'psql -c "DROP TABLE users"'
assert_contains "$ERR" "Maude [RED]:" "drop-table tagged"
run_gate 'rm -rf /'
assert_contains "$ERR" "Maude [RED]:" "rm-rf-root tagged"
run_gate 'gh release create v9.9.9'
assert_contains "$ERR" "Maude [RED]:" "public-publish tagged"

test_start "a pass on a live token says so, so a spent token leaves a trace on screen"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "0" "passes on the token"
assert_contains "$ERR" "git-push passed on its token" "the pass is spoken"

# ── One token opens exactly one command, under concurrency (the memory lens, 2026-09-06,
# DEFECT-4: the gate read the token on one open and consumed it on a second, so a
# concurrent writer could resurrect a spent token). A jq shim that sleeps makes two gate
# runs overlap deterministically: both read the token live unless read-and-consume is
# one locked step.
test_start "one token opens exactly one of two concurrent gated commands"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
RACEJQ="$(make_no_binary_bin jq)"; REAL_JQ="$(command -v jq)"
printf '#!/usr/bin/env bash\n%q 0.2\nexec %q "$@"\n' "$(command -v sleep)" "$REAL_JQ" > "$RACEJQ/jq"; chmod +x "$RACEJQ/jq"
( make_bash_tool_input "git push origin main" | PATH="$RACEJQ:$PATH" bash "$GATE" >/dev/null 2>&1; echo $? > "$TEST_TMP/race-rc1" ) &
( make_bash_tool_input "git push origin main" | PATH="$RACEJQ:$PATH" bash "$GATE" >/dev/null 2>&1; echo $? > "$TEST_TMP/race-rc2" ) &
wait
RACE_PASSES=0; [ "$(cat "$TEST_TMP/race-rc1")" = 0 ] && RACE_PASSES=$((RACE_PASSES + 1)); [ "$(cat "$TEST_TMP/race-rc2")" = 0 ] && RACE_PASSES=$((RACE_PASSES + 1))
assert_eq "$RACE_PASSES" "1" "exactly one of two overlapping commands passed on one token"
# The pass RESERVES; the spend is the run (PostToolUse consume, test above). Prove both halves:
# the token is still there for the command that passed, and its consume takes it.
assert_ne "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "and the token is reserved, not yet spent"
make_bash_tool_input "git push origin main" | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "and the run spends it"

test_start "a live token whose reservation cannot be written refuses and SAYS the write failed (not 'go get a token')"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
BADJQ="$(make_no_binary_bin jq)"
printf '#!/usr/bin/env bash\ncase "$*" in *reserved*) exit 4;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$BADJQ/jq"; chmod +x "$BADJQ/jq"
ERR="$(make_bash_tool_input "git push origin main" | PATH="$BADJQ:$PATH" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "fail closed"
assert_contains "$ERR" "could not record" "says the write failed"
assert_not_contains "$ERR" "Run /maude:conscience" "does not send him for a token he holds"
# ── a heredoc body is text, for the wrapped-payload scan too (2026-09-28) ──
# The plain patterns already excised heredoc bodies (v0.27.0); the bash -c / eval payload
# scan did not, so a python heredoc that merely carried the string
# "bash -c 'git commit -m m --amend'" was blocked (found live, on an edit to this file).
# A heredoc FED TO A SHELL runs its body, so there the scan still reads it.
rm -f "$(care_path)"
HD1=$'python3 - <<\x27PY\x27\nx = "bash -c \x27git commit -m m --amend\x27"\nPY'
HD2=$'cat > f.txt <<EOF\nrun: bash -c \x27git reset x --hard\x27\nEOF'
test_start "a wrapped gated command inside a python heredoc body is text, not a command"
run_gate "$HD1"; assert_exit "$RC" "0" "passes"
test_start "a wrapped gated command inside a cat heredoc body is text, not a command"
run_gate "$HD2"; assert_exit "$RC" "0" "passes"
HS1=$'bash <<EOF\nbash -c \x27git commit -m m --amend\x27\nEOF'
HS2=$'sh -s <<\x27EOF\x27\nbash -c \x27git reset x --hard\x27\nEOF'
test_start "control: a heredoc fed to bash still has its wrapped payload read"
run_gate "$HS1"; assert_exit "$RC" "2" "blocked"
test_start "control: a heredoc fed to sh -s still has its wrapped payload read"
run_gate "$HS2"; assert_exit "$RC" "2" "blocked"
test_start "control: a real bash -c after a heredoc still blocks"
run_gate $'cat > f <<EOF\nhello\nEOF\nbash -c \x27git commit -m m --amend\x27'
assert_exit "$RC" "2" "blocked"

# ── the shell-fed decision is per opener line, on the stripped command (lens round 1) ──
# The first cut grepped the WHOLE command for a shell word before a `<<`: the standard
# commit shape (`git add . && git commit -m "$(cat <<'EOF'`) read the standalone `.` as
# `source`, a `cat > x.sh <<EOF` read `.sh` as `sh`, and a body that merely mentioned
# `bash <<EOF` flipped the verdict; meanwhile `cat <<EOF | bash` read as text because the
# shell came AFTER the heredoc. Each shape below is a text body that must PASS or an
# executing body that must BLOCK; the payload is the same wrapped amend in every one.
rm -f "$(care_path)"
test_start "the standard commit shape with a wrapped command quoted in its message is text"
run_gate $'git add . && git commit -m "$(cat <<\'EOF\'\nnote: '"$WRAP"$' is caught\nEOF\n)"'
assert_exit "$RC" "0" "passes"
test_start "a heredoc written to a .sh file is text (\`.sh\` is not the shell word \`sh\`)"
run_gate $'cat >> tests/test-gate.sh <<\'EOF\'\nrun_gate "'"$WRAP"$'"\nEOF'
assert_exit "$RC" "0" "passes"
test_start "a heredoc written to a .bash file is text"
run_gate $'cat > hooks/x.bash <<\'EOF\'\n'"$WRAP"$'\nEOF'
assert_exit "$RC" "0" "passes"
test_start "a path containing a shell word is not a shell word (notes/bash-tips.md)"
run_gate $'cat > notes/bash-tips.md <<EOF\n'"$WRAP"$'\nEOF'
assert_exit "$RC" "0" "passes"
test_start "a python body that MENTIONS bash <<EOF does not flip the verdict"
run_gate $'python3 - <<PY\ndoc = """\nrun it with bash <<EOF\n"""\nx = "'"$WRAP"$'"\nPY'
assert_exit "$RC" "0" "passes"
test_start "a standalone dot in an EARLIER segment is not source"
run_gate $'cd . && python3 - <<PY\nx = "'"$WRAP"$'"\nPY'
assert_exit "$RC" "0" "passes"
# The other direction: the body RUNS, so the wrapped payload in it must still block.
for shape in \
  $'cat <<EOF | bash\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > x.sh && bash x.sh\n'"$WRAP"$'\nEOF' \
  $'tee x.sh <<EOF && bash x.sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | ssh host bash\n'"$WRAP"$'\nEOF' \
  $'ssh host <<EOF\n'"$WRAP"$'\nEOF' \
  $'ssh -T host <<\'EOF\'\n'"$WRAP"$'\nEOF' \
  $'su root <<EOF\n'"$WRAP"$'\nEOF' \
  $'sudo -i <<EOF\n'"$WRAP"$'\nEOF' \
  $'sudo bash <<EOF\n'"$WRAP"$'\nEOF' \
  $'/bin/bash <<EOF\n'"$WRAP"$'\nEOF' \
  $'/usr/bin/env bash <<EOF\n'"$WRAP"$'\nEOF' \
  $'docker exec -i c sh <<EOF\n'"$WRAP"$'\nEOF' \
  $'pct exec 100 -- bash <<EOF\n'"$WRAP"$'\nEOF' \
  $'chroot /x <<EOF\n'"$WRAP"$'\nEOF' \
  $'zsh <<EOF\n'"$WRAP"$'\nEOF' \
  $'dash <<EOF\n'"$WRAP"$'\nEOF' \
  $'ksh <<EOF\n'"$WRAP"$'\nEOF' \
  $'bash -s <<EOF\n'"$WRAP"$'\nEOF' \
  $'bash <<-EOF\n'"$WRAP"$'\nEOF' \
  $'(bash) <<EOF\n'"$WRAP"$'\nEOF' \
  $'. /dev/stdin <<EOF\n'"$WRAP"$'\nEOF' \
  $'source /dev/stdin <<EOF\n'"$WRAP"$'\nEOF' \
  $'echo x; bash <<EOF\n'"$WRAP"$'\nEOF' \
  ; do
  test_start "an executing body still blocks: ${shape%%$'\n'*}"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"
done
# The control for the direction: with the SAME opener and no wrapped payload, nothing to
# block, so a block above comes from the payload and not from the opener itself.
test_start "control: an executing opener with a harmless body passes"
run_gate $'cat <<EOF | bash\necho hi\nEOF'
assert_exit "$RC" "0" "passes"

# ── everything AFTER the opener counts (lens round 2) ──────────────────────────────
# "The segment after" was one segment too few: write, chmod, run; a pipe through tee; a
# run on a later line. And the shell list was short, `bash<<EOF` hid the word behind `<`,
# `eval` had dropped off, and `sudo` only knew `-i`/`-s` as its first option.
for shape in \
  $'cat <<EOF > x.sh; chmod +x x.sh; bash x.sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | tee x | bash\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | grep . | sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > x.sh\n'"$WRAP"$'\nEOF\nbash x.sh' \
  $'cat <<EOF > x.sh\n'"$WRAP"$'\nEOF\nchmod +x x.sh\nsh x.sh' \
  $'bash<<EOF\n'"$WRAP"$'\nEOF' \
  $'sh<<\'EOF\'\n'"$WRAP"$'\nEOF' \
  $'/bin/sh<<EOF\n'"$WRAP"$'\nEOF' \
  $'eval "$(cat <<\'EOF\'\n'"$WRAP"$'\nEOF\n)"' \
  $'cat <<EOF | sudo -u root -i\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | sudo -E -s\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | sudo --login\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | ash\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | tcsh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | rbash\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | mksh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | $SHELL\n'"$WRAP"$'\nEOF' \
  $'{ bash; } <<EOF\n'"$WRAP"$'\nEOF' \
  $'x=`bash <<EOF\n'"$WRAP"$'\nEOF\n`' \
  ; do
  test_start "an executing body still blocks (after the opener): ${shape%%$'\n'*}"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"
done
# ── round 3: the opener that was not one, the file run by path, `>` as a boundary ──
for shape in \
  $'# note <<EOF\nbash <<EOF\n'"$WRAP"$'\nEOF' \
  $'echo a # <<EOF\nbash <<EOF\n'"$WRAP"$'\nEOF' \
  $'echo a \\<<EOF\nbash <<EOF\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > r.sh; chmod +x r.sh; ./r.sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > r.sh\n'"$WRAP"$'\nEOF\nchmod +x r.sh\n./r.sh' \
  $'cat <<EOF > /tmp/r; chmod +x /tmp/r; /tmp/r\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > r.sh; sudo ./r.sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > r; at -f r now\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF > x.sh; . x.sh\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | sh>out\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | sh>/dev/null\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | docker exec -i c \'bash\'\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | pct exec 1 -- "bash"\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | ${SHELL}\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | $BASH\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | $0\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | tee "it\'s" | bash -s -- \'z\'\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | FOO=1 sudo -i\n'"$WRAP"$'\nEOF' \
  $'cat <<EOF | tee x\n'"$WRAP"$'\nEOF\ncat x | sh>out' \
  $'cat <<EOF > r.sh\n'"$WRAP"$'\nEOF\nchmod +x r.sh; ./r.sh; echo done' \
  $'cat <<EOF > r.sh\n'"$WRAP"$'\nEOF\nchmod +x r.sh; (./r.sh)' \
  $'cat <<EOF > r.sh\n'"$WRAP"$'\nEOF\nchmod +x r.sh; ./r.sh>/dev/null' \
  $'cat <<EOF | tee "it\'s" | bash -s -- \'a b\'\n'"$WRAP"$'\nEOF' \
  ; do
  test_start "an executing body still blocks (round 3): ${shape%%$'\n'*}"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"
done
test_start "a quoted mention on a later line is blanked, not read as a shell word"
run_gate $'cat <<EOF > notes.md\n'"$WRAP"$'\nEOF\necho "then run bash later"'
assert_exit "$RC" "0" "passes"
test_start "a file whose name merely PREFIXES a later word is not the file"
run_gate $'cat <<EOF > r.sh\n'"$WRAP"$'\nEOF\nls r.sh.bak r.sh-old'
assert_exit "$RC" "0" "passes"
test_start "a file written by the heredoc and merely READ later is text"
run_gate $'cat <<EOF > notes.md\n'"$WRAP"$'\nEOF\nwc -l other.md'
assert_exit "$RC" "0" "passes"

# Text after the opener stays text: nothing on the later lines is a shell word.
test_start "a commit message heredoc followed by a push is still text"
run_gate $'git add . && git commit -m "$(cat <<\'EOF\'\nnote: '"$WRAP"$' is caught\nEOF\n)" && git push origin main'
printf '%s' "$ERR" | grep -q "commit-amend"; assert_exit "$?" "1" "the amend in the message is not read"
test_start "a notes heredoc followed by an echo is text"
run_gate $'cat <<EOF > notes.md\n'"$WRAP"$'\nEOF\necho done'
assert_exit "$RC" "0" "passes"

print_summary
teardown_test_env
exit $FAILED
