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
# A reservation's identity is the exact CALL: the session and the cksum of its tool_input
# bytes, computed the way the gate computes it. Seeds a reservation by hand:
#   seed_reserved <token-file> <key> <sid> <age-seconds> <command>
# Exactly as maude_call_fp hashes: keys SORTED, and NO trailing newline (jq prints one;
# the lib's command substitution drops it, so a seeded fp must drop it too).
# … and the tool NAME with them (lens 6): the same bytes under another tool are another call.
fp_of() { printf '%s' "$(make_bash_tool_input "$1" | jq -Sc '{n: (.tool_name // ""), i: (.tool_input // {})}')" | cksum | awk '{print $1}'; }
seed_reserved() {
  printf '{"gate_cleared":{"%s":{"until":%d,"reserved":{"sid":"%s","at":%d,"fp":"%s","head":"%.60s","v":3}}}}\n' \
    "$2" $(($(date +%s) + 600)) "$3" $(($(date +%s) - $4)) "$(fp_of "$5")" "$5" > "$1"
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

# A token is SPENT when the command RUNS, not when this gate lets it through. PreToolUse
# hooks run in parallel and any sibling can refuse the same command (the version gate did
# on 2026-09-06, the classifier on 09-05), and PostToolUse never fires for a refused
# command. Consuming here spent a clear on a push that never happened and cost a second
# clear every time. So the gate RESERVES the token for this session at PreToolUse and
# CONSUMES it at PostToolUse of the command that actually ran (`consume` mode, called
# from maude-trace.sh). The reservation belongs to the exact CALL, session + tool_input
# bytes (the 24th lens, BLOCKING-2: a reservation of {sid, at} was a LEASE: one clear
# opened a different command of the same session 4 s later, another session's after a
# 120 s window, red keys included). Only the same call again rides it; nothing else
# does until the clear expires or is made again.
test_start "the pass RESERVES the token for this session and does not spend it"
assert_ne "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "token still present after the pass"
assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid')" "default" "reserved by this session"

test_start "two commands of one session in the same instant: one token opens ONE (the second is in flight)"
run_gate "git push origin main"
assert_exit "$RC" "2" "the second, moments later, is blocked"
assert_contains "$ERR" "already passing" "and told a command of its own holds the token"

test_start "a command a sibling hook refused does not spend it: the same call passes again, seconds later"
seed_reserved "$(care_path)" git-push default 5 "git push origin main"
run_gate "git push origin main"
assert_exit "$RC" "0" "a retry of the same call passes on its own reservation"

test_start "the SAME session with DIFFERENT bytes 4 s later is refused, and told who holds it (BLOCKING-2 a)"
seed_reserved "$(care_path)" git-push default 4 "git push origin main"
run_gate "git push origin release"
assert_exit "$RC" "2" "a different command does not ride the reservation"
assert_contains "$ERR" "git push origin main" "names the call that holds it"
assert_contains "$ERR" "left" "and how long the clear has left"

test_start "a DIFFERENT session cannot ride a fresh reservation"
ERR="$(make_bash_tool_input "git push origin main" | jq -c '. + {session_id:"other000-zzzz"}' | bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "other session blocked while reserved"
assert_contains "$ERR" "reserved" "and told why"

test_start "PostToolUse consume SPENDS the token: the command ran"
ERR="$(make_bash_tool_input "git push origin main" | jq -c '. + {hook_event_name:"PostToolUse", tool_response:{stdout:"",stderr:"",interrupted:false}}' | bash "$GATE" consume 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "consume never blocks"
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "token cleared"
assert_contains "$ERR" "is spent" "the spend is spoken"

test_start "second matching command after the spend re-blocks"
run_gate "git push origin main"
assert_exit "$RC" "2" "second push blocked again"

test_start "consume with NO token is silent and exits 0"
ERR="$(make_bash_tool_input "git push origin main" | bash "$GATE" consume 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "exit 0"
assert_eq "$ERR" "" "nothing said"

test_start "an ORPHANED reservation is not free to another session: it holds until the clear expires (BLOCKING-2 b)"
seed_reserved "$(care_path)" git-push default 400 "git push origin main"
ERR="$(make_bash_tool_input "git push origin main" | jq -c '. + {session_id:"other000-zzzz"}' | bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "no takeover window"
assert_contains "$ERR" "reserved" "and told it is reserved"
assert_eq "$(read_care '.gate_cleared["git-push"].reserved.sid')" "default" "still the first call's"

test_start "consume with DIFFERENT bytes leaves the token: it was reserved against another call (T8)"
seed_reserved "$(care_path)" git-push default 0 "git push origin main"
make_bash_tool_input "git push origin release" | bash "$GATE" consume >/dev/null 2>&1
assert_ne "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "token kept for its reserver"

test_start "consume with the SAME bytes and NO session_id spends it: that command ran (MINOR-1)"
seed_reserved "$(care_path)" git-push f4ba50d9 0 "git push origin main"
make_bash_tool_input "git push origin main" | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "spent on the bytes, not the session"
rm -f "$(care_path)"

# A corrupt care.json must not blind the OTHER token file: red keys live in one and yellow
# in the other, so one bad store vetoing the good one turned a one-shot RED clear into an
# N-shot (the 26th lens, IMPORTANT-2).
test_start "a corrupt care.json does not stop a live RED token from being spent (26th lens, IMPORTANT-2)"
printf '{"gate_cleared":{"force-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(redclear_path)"
run_gate "git push --force origin main"
assert_exit "$RC" "0" "the red clear passes"
printf 'not json at all {{{\n' > "$(care_path)"
make_bash_tool_input "git push --force origin main" | jq -c '. + {hook_event_name:"PostToolUse"}' | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(jq -r '.gate_cleared["force-push"].until // "absent"' "$(redclear_path)")" "absent" "and the run spends it even with care.json corrupt"
rm -f "$(care_path)" "$(redclear_path)"

# The head was cut at 60 BYTES, so a multibyte character straddling the cut left a lone
# byte that jq rewrote to U+FFFD on the way in; the two ends then compared different bytes,
# the retry was refused and the clear never spent (the 26th lens, IMPORTANT-3).
test_start "on a box that cannot hash, a command cut mid-UTF-8-character still rides its own reservation (26th lens, IMPORTANT-3)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
NOCK2="$(make_no_binary_bin cksum shasum sum python3)"
UTF8CMD="git push origin main # $(printf 'a%.0s' $(seq 1 36))é and more"
ERR="$(make_bash_tool_input "$UTF8CMD" | PATH="$NOCK2" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "the first call passes"
sleep 4
ERR="$(make_bash_tool_input "$UTF8CMD" | PATH="$NOCK2" bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "and the same call retried is not refused"
make_bash_tool_input "$UTF8CMD" | jq -c '. + {hook_event_name:"PostToolUse"}' | PATH="$NOCK2" bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "and the run spends it"
rm -f "$(care_path)"

# A reservation this build cannot identify — any older shape, including the one the
# PREVIOUS build wrote with a different fingerprint formula — names no call it can match,
# so it is re-reservable and spendable rather than a hard refusal of the person's own
# command (the 26th lens, IMPORTANT-4).
test_start "a reservation from the PREVIOUS build's formula is re-reservable, and the run spends it (26th lens, IMPORTANT-4)"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"other000","at":%d,"fp":"3753488038","head":"git push origin main"}}}}\n' $(($(date +%s) + 600)) $(($(date +%s) - 60)) > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "0" "an unversioned reservation does not refuse the person's own command"
make_bash_tool_input "git push origin main" | jq -c '. + {hook_event_name:"PostToolUse"}' | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "and the run spends it"

test_start "a farm with shasum but no cksum still fingerprints (27th lens, IMPORTANT-3: the middle links are reachable)"
SHAONLY="$(make_no_binary_bin cksum sum python3)"   # shasum is the ONLY link left: name the one under test
FPSHA="$(PATH="$SHAONLY" bash -c '. '"$HOOKS_DIR"'/_maude-common.sh; maude_call_fp '"'"'{"tool_input":{"command":"git push origin main"}}'"'"'')"
[ -n "$FPSHA" ]
assert_exit "$?" "0" "a box with shasum and no cksum produces a fingerprint"

test_start "an EXPIRED token is pruned when another is written, so the cheap exit stays cheap (26th lens, MINOR-4)"
printf '{"gate_cleared":{"stale-one":{"until":1},"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git push origin main"
assert_eq "$(read_care '.gate_cleared["stale-one"] // "gone"')" "gone" "the expired token is gone"
assert_ne "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "the live one stays"
rm -f "$(care_path)"

test_start "a version written as a STRING is read the same by the fast path and the slow one (27th lens, MINOR-4)"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"other000","at":%d,"fp":"999999999","head":"git push origin other","v":"3"}}}}\n' $(($(date +%s) + 600)) $(($(date +%s) - 60)) > "$(care_path)"
SPENDABLE=0; . "$HOOKS_DIR/_maude-common.sh"
maude_gate_spendable_here '{"tool_input":{"command":"git push origin main"}}' "git push origin main" "$(care_path)" && SPENDABLE=1
assert_eq "$SPENDABLE" "0" "the fast path agrees with the slow one: a v3 reservation of another call is not spendable"
rm -f "$(care_path)"

test_start "a reservation written BEFORE the fingerprint existed names no call: re-reservable, and spent by the run (the upgrade path)"
printf '{"gate_cleared":{"git-push":{"until":%d,"reserved":{"sid":"other000","at":%d}}}}\n' $(($(date +%s) + 600)) $(($(date +%s) - 5)) > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "0" "a legacy reservation does not block a new call"
assert_eq "$(read_care '.gate_cleared["git-push"].reserved.fp // "absent"')" "$(fp_of "git push origin main")" "it is re-reserved with a real fingerprint"
make_bash_tool_input "git push origin main" | jq -c '. + {hook_event_name:"PostToolUse"}' | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "and the run spends it"

test_start "the fingerprint is CONTENT, not byte order: a Post whose tool_input keys are in another order still spends (25th lens, IMPORTANT-2)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
make_bash_tool_input "git push origin main" | jq -c '.tool_input = {command:"git push origin main", description:"push"}' | bash "$GATE" >/dev/null 2>&1
make_bash_tool_input "git push origin main" | jq -c '. + {hook_event_name:"PostToolUse"} | .tool_input = {description:"push", command:"git push origin main"}' | bash "$GATE" consume >/dev/null 2>&1
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "the same call in another key order spends it"

test_start "without cksum the retry after a sibling refusal still passes: the fix is not reversed (25th lens, IMPORTANT-3)"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
# EVERY link of the fingerprint chain, excluded at construction, so this really is a box that
# cannot hash (the farm links cksum, shasum, sum and python3 — excluding only two of them left
# this test running on the shasum path, where the fingerprint does the telling and the head
# identity below is never exercised: the 27th lens, IMPORTANT-3). Excluded, never written
# over: the dir holds symlinks only.
NOCK="$(make_no_binary_bin cksum shasum sum python3)"
run_gate_nock() { ERR="$(make_bash_tool_input "$1" | PATH="$NOCK" bash "$GATE" 2>&1 >/dev/null)"; RC=$?; }
run_gate_nock "git push origin main"
assert_exit "$RC" "0" "the first call passes"
sleep 4
run_gate_nock "git push origin main"
assert_exit "$RC" "0" "and the same call retried passes, not refused"

test_start "…while a DIFFERENT command is still refused on a box that cannot hash"
run_gate_nock "git push origin release"
assert_exit "$RC" "2" "a different command does not ride it"
rm -f "$(care_path)"

test_start "a RED token is one shot too: a different force-push 4 s later is refused (BLOCKING-2 c)"
seed_reserved "$(redclear_path)" force-push default 4 "git push --force origin main"
run_gate "git push --force origin release"
assert_exit "$RC" "2" "different bytes refused on a red reservation"
assert_contains "$ERR" "reserved" "and told it is reserved"

test_start "…and another session after 121 s is refused: the takeover is gone for red keys"
seed_reserved "$(redclear_path)" force-push default 121 "git push --force origin main"
ERR="$(make_bash_tool_input "git push --force origin main" | jq -c '. + {session_id:"other000-zzzz"}' | bash "$GATE" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "no takeover"

test_start "…while the same force-push retried after a sibling refusal rides its own reservation"
seed_reserved "$(redclear_path)" force-push default 4 "git push --force origin main"
run_gate "git push --force origin main"
assert_exit "$RC" "0" "same call: the retry passes"
rm -f "$(redclear_path)"

test_start "a token whose 'until' is not a number blocks without a bash error in her voice"
printf '{"gate_cleared":{"git-push":{"until":"soon"}}}\n' > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "2" "blocked"
assert_not_contains "$ERR" "integer expression" "no raw bash error on the person's channel"

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

test_start "red-self-clear block names it the account owner's hand, never a person's name"
assert_contains "$ERR" "account owner" "block message names the account owner"
assert_not_contains "$ERR" "John" "block message carries no maintainer name"

test_start "gate BLOCKS red clear-script even with a quoted script path"
run_gate 'bash "/x/hooks/scripts/maude-clear-gate.sh" force-push --john'
assert_exit "$RC" "2" "quoted-path red self-clear blocked"

# The two backstop refusals ABOUT red keys are red refusals too: they opened with the
# yellow prefix and carried no red sentence, one of them saying "is a RED key" while
# wearing `Maude:` (the 23rd lens, IMPORTANT-3, the D3 confusion the wave was written
# to remove).
test_start "the red self-clear backstop opens with the red tag and carries the red sentence"
run_gate 'bash /x/hooks/scripts/maude-clear-gate.sh force-push --john'
assert_contains "$ERR" "Maude [RED]:" "tagged red"
assert_contains "$ERR" '"force-push" is a RED key' "the red sentence names the key"
assert_contains "$ERR" "/maude:conscience force-push" "and the command that shows the line"

test_start "the red-clear-file write backstop opens with the red tag and names whose hand it is"
run_gate 'echo {} > /x/.maude/plugin/care-redclear.json'
assert_contains "$ERR" "Maude [RED]:" "tagged red"
assert_contains "$ERR" "hand" "whose hand"
assert_not_contains "$ERR" "Run /maude:conscience" "no yellow self-clear instruction"

test_start "the public-publish refusal keeps its checklist clause after the strip"
run_gate "gh release create v1.0 dist/*"
assert_contains "$ERR" "checklist" "the pre-public-push checklist is still named"

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
WRAP="bash -c 'git commit -m m --amend'"
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

# ── lens on merged main b2faa51 (2026-10-02): the opener line is not always where the shell ──
# word is, the stripper opened phantom bodies on lines bash does not, and a shell can be spelled
# one indirection away. Every shape here was RED on main before the heredoc branch and passed
# after it. The payload is a wrapped force-push; for the stripper cases the BARE form is pinned
# too, because that is the form the PLAIN patterns read — if only the wrapped form blocks, the
# fix went into the shell-fed scan and the stripper is still blind.
rm -f "$(care_path)"
FP="eval 'git push --force'"
# F1: the shell is on the line before the opener.
for shape in \
  $'bash \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'sudo -i \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'ssh host \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'(\nbash\n) <<EOF\n'"$FP"$'\nEOF' \
  $'{\n  sh\n} <<EOF\n'"$FP"$'\nEOF' \
  $'echo start \\\n  && bash \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'sudo \\\n-i <<EOF\n'"$FP"$'\nEOF' \
  $'ssh \\\nhost <<EOF\n'"$FP"$'\nEOF' \
  $'bash \\\n-s <<EOF\n'"$FP"$'\nEOF' \
  ; do
  # The last three put a non-shell word before the `<<` on the opener line, so only the
  # continuation join (not the group lookback) can see the shell: one rule, one fixture.
  test_start "a shell on the line before the opener feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The allowlist (2026-10-04) strips only after lines it can prove bash reads the same way; a
# `\` continuation, a group, an escape, an unclosed quote or an odd delimiter is not one, so
# the text heredocs below are read in full and their gated text blocks: named cost, each
# confirmed by the bash oracle as a body bash never runs.
test_start "a continuation before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'cat \\\n<<EOF > notes.md\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
test_start "a group before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'(\necho hi\n) <<EOF\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
# F2: lines the stripper read as openers that bash does not. Wrapped AND bare.
for pre in \
  $'cat <<END-OF-FILE\nx\nEND-OF-FILE' \
  $'cat <<E.F\nx\nE.F' \
  $'cat <<EOF.txt\nx\nEOF.txt' \
  $'echo "\\"<<EOF"' \
  $'echo $\'\\\'<<EOF\'' \
  $'echo $(( (n+1) << k ))' \
  $'echo ${x:-<<EOF}' \
  ; do
  test_start "no phantom body after $(printf '%q' "${pre%%$'\n'*}"): a wrapped force-push on the next line blocks"
  run_gate "$pre"$'\n'"$FP"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "no phantom body after $(printf '%q' "${pre%%$'\n'*}"): a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a real heredoc with a hyphenated delimiter still hides its body"
run_gate $'cat <<END-OF-FILE > n.md\ngit push --force\nEND-OF-FILE'
assert_exit "$RC" "0" "passes"
test_start "the closing line of a hyphenated delimiter is honoured (text after it is read)"
run_gate $'cat <<E-F > n.md\nx\nE-F\ngit push --force'
assert_exit "$RC" "2" "blocked"
# F3: a shell spelled one indirection away.
for shape in \
  $'SH=bash; $SH <<EOF\n'"$FP"$'\nEOF' \
  $'"$SH" <<EOF\n'"$FP"$'\nEOF' \
  $'${0} <<EOF\n'"$FP"$'\nEOF' \
  $'${SHELL} <<EOF\n'"$FP"$'\nEOF' \
  $'sudo . /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'sudo -u root source /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'b\\ash <<EOF\n'"$FP"$'\nEOF' \
  $'cat <<EOF | $SH\n'"$FP"$'\nEOF' \
  $'cat <<EOF | sudo $SH\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell one indirection away feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The named cost of fail-closed on a variable in command position: an interpreter held in a
# variable keeps its body in the wrapped scan.
test_start "named cost: \$PYTHON - <<PY quoting a wrapped amend is read (blocked)"
run_gate $'$PYTHON - <<PY\nx = "'"$WRAP"$'"\nPY'
assert_exit "$RC" "2" "blocked"
test_start "a variable NOT in command position is not a shell (echo \$X after a text heredoc)"
run_gate $'cat <<EOF > f.txt\n'"$FP"$'\nEOF\necho $X'
assert_exit "$RC" "0" "passes"
test_start "a variable assignment before a text heredoc is not a shell"
run_gate $'OUT=$DIR/f.txt; cat <<EOF > $OUT\n'"$FP"$'\nEOF'
assert_exit "$RC" "0" "passes"

# ── lens round 2 on the fold (2026-10-02): the blanker must not MAKE an opener, the shell ──
# word may hide behind a prefix, and sudo's `-u` takes its argument.
rm -f "$(care_path)"
# A `<<` bash reads as a shift or a literal is not an opener; a bare force-push after it blocks.
for pre in \
  '(( x = 1 << 2 ))' \
  '(( x <<= 2 ))' \
  'echo $[1<<2]' \
  'a[1<<2]=3' \
  'echo $(( $(( 1 )) << 2 ))' \
  'echo \<\<EOF' \
  'echo <\<EOF' \
  'cat <\< EOF' \
  "echo <''<EOF" \
  'echo |#}x<<22' \
  ; do
  test_start "not an opener: $(printf '%q' "$pre") — a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a trailing backslash on the opener line continues the COMMAND; the body starts after it"
run_gate $'cat <<E |\\\ngit push --force\nbody\nE'
assert_exit "$RC" "2" "blocked"
# Round 6: a backslash at the end of a COMMENT continues nothing; the body starts on the next
# line and closes at the first EOF, so the push after that close is read.
test_start "a trailing backslash inside a comment on the opener line is not a continuation"
run_gate $'cat <<EOF # x \\\nEOF\ngit push --force\nEOF'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "an odd run of backslashes at the end of the opener line IS a continuation (the next line is command)"
run_gate $'cat <<EOF x\\\\\\\n; git push --force\na\nEOF'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "backslashes on the opener line: the body is read in full (allowlist cost: read in full)"
run_gate $'cat <<EOF x\\\\\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# Round 6 finish: the closing line is recognised exactly as bash recognises it. Closing EARLY
# is not safe either: body text after a too-early close can open a phantom body whose close
# sits after bash's real one and hides the lines between (oracle RAN on each, merged passed).
for c in $'cat <<\'EOF\'\nEOF \ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nEOF \ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\n  EOF\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nx\\\nEOF\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nEOF\r\ncat <<Z\nEOF\ngit push --force\nZ'; do
  test_start "a closer bash does not close on does not close the body here: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# An unquoted body joins `\`⏎ before the closer is compared (`<<-` strips tabs from the
# joined line's start only); a quoted or escaped delimiter does not join.
for c in $'cat <<EOF\nEO\\\nF\ngit push --force\nEOF' \
         $'cat <<EOF\nE\\\nO\\\nF\ngit push --force\nEOF' \
         $'cat <<EOF\nEOF\\\n\ngit push --force\nEOF' \
         $'cat <<-EOF\n\tEO\\\nF\ngit push --force\nEOF' \
         $'cat <<\'EOF\'\nx\\\nEOF\ngit push --force' \
         $'cat <<\\EOF\nx\\\nEOF\ngit push --force' \
         $'cat <<\'EOF\'\nx\\\nEOF\ngit push --force\nEOF' \
         $'cat <<"EOF"\nx\\\nEOF\ngit push --force\nEOF' \
         $'cat <<\\EOF\nx\\\nEOF\ngit push --force\nEOF'; do
  test_start "the body closes where bash closes it, joined or not: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<EOF\nEO\\\nF\necho done' \
         $'cat <<-EOF\n\t'"$FP"$'\n\tEOF\necho done' \
         $'cat <<EOF\nx\\\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\'\nx\\\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF\nx\\\\\nEOF\necho done'; do
  test_start "a text heredoc closed where bash closes it stays hidden: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
# Round 7: a delimiter word runs to a metacharacter. `cat <<EOF{` is delimited by `EOF{` in
# bash; read as `EOF` it closed past bash's close and hid the push between (merged too,
# oracle RAN). A word with a character outside the class before its end opens no body.
for s in '{' '}' '^' ']' '[' '$' '$X' '{a,b}' '[a]' '^^' '}}'; do
  c="cat <<EOF$s"$'\nx\n'"EOF$s"$'\ngit push --force\nEOF'
  test_start "a delimiter word does not stop short of its end: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<-EOF}\n\tEOF}\ngit push --force\nEOF' \
         $'cat <<\'EOF\'^\nEOF^\ngit push --force\nEOF' \
         $'cat <<\\EOF}\nEOF}\ngit push --force\nEOF' \
         $'cat <<"EOF"[\nEOF[\ngit push --force\nEOF'; do
  test_start "a quoted, escaped or dashed delimiter does not stop short of its end: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<A<<B\n'"$FP"$'\nA\n'"$FP"$'\nB\necho done' \
         $'cat <<EOF>/dev/null\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF;echo x\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF|cat\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF&&true\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\'>/dev/null\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\\EOF;echo x\n'"$FP"$'\nEOF\necho done' \
         $'cat <<-EOF\t\n\t'"$FP"$'\n\tEOF\necho done'; do
  test_start "a delimiter ended by a metacharacter still hides its body: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
test_start "a subshell around the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'(cat <<EOF)\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# Round 8: a word ends where BASH ends it — a space, a tab, a newline, or `; | & < > )`. A
# `\r` `\v` `\f` is part of bash's word (`[[:space:]]` ended it here, and merged blocked these
# only because its closer was trimmed); `(` after the word is extglob's `@(x)` once
# `shopt -s extglob` ran; a Unicode space is a word character to bash while a UTF-8 sed reads
# it as space. Each made the gate key a shorter delimiter than bash's (oracle RAN).
for ws in $'\r' $'\v' $'\f'; do
  for open in "<<EOF$ws" "<<'EOF'$ws" "<<\\EOF$ws" "<<\"EOF\"$ws"; do
    c="cat $open"$'\n'"EOF$ws"$'\ngit push --force\nEOF'
    test_start "a word does not end at a byte bash reads as part of it: $(printf '%q' "$c")"
    run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
for c in $'cat <<-EOF\r\n\tEOF\r\ngit push --force\nEOF' \
         $'cat <<EOF\r <<B\nEOF\r\nB\ngit push --force\nEOF' \
         $'shopt -s extglob\ncat <<@(x)\n@(x)\ngit push --force\n@' \
         $'shopt -s extglob\ncat <<!(x)\n!(x)\ngit push --force\n!' \
         $'shopt -s extglob\ncat <<+(x)\n+(x)\ngit push --force\n+' \
         $'shopt -s extglob\ncat <<*(x)\n*(x)\ngit push --force\n*' \
         $'shopt -s extglob\ncat <<?(x)\n?(x)\ngit push --force\n?' \
         $'shopt -s extglob\ncat <<@(x|y)\n@(x|y)\ngit push --force\n@' \
         $'shopt -s extglob\ncat <<-@(x)\n\t@(x)\ngit push --force\n@'; do
  test_start "a word bash reads whole is not keyed short: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# … and before the word too: `<<\v'EOF'` is delimited by `\vEOF` in bash; read as a quoted
# `EOF` the body closed EARLY and body text opened a phantom over the push.
for ws in $'\v' $'\r' $'\f'; do
  for q in "'EOF'" '"EOF"' '\EOF'; do
    c="cat <<$ws$q"$'\nEOF\ncat <<Z\n'"${ws}EOF"$'\ngit push --force\nZ'
    test_start "a byte bash reads into the word does not separate << from it: $(printf '%q' "$c")"
    run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
# A word the gate cannot read opens no body, so bash's body text is read here as commands; a
# `cat <<Z` in it opened a phantom whose `Z` hid a push bash runs after its real close (merged
# too, oracle RAN). From the first uncertain `<<` on, no opener is trusted.
for c in $'cat <<EOF{\ncat <<Z\nEOF{\ngit push --force\nZ' \
         $'cat <<E\'O\'F\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<\\#\\#\ncat <<Z\n##\ngit push --force\nZ'; do
  test_start "after a word the gate cannot read, a later opener is not trusted: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'echo "use <<\'E F\' here"\ncat <<EOF\n'"$FP"$'\nEOF\necho done' \
         $'echo hi # see <<E\'O\'F\ncat <<EOF\n'"$FP"$'\nEOF\necho done'; do
  test_start "an uncertain << inside a string or a comment distrusts nothing: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
for loc in C C.UTF-8 en_US.UTF-8; do
  for u in $' ' $'　' $' '; do
    c="cat <<EOF${u}x"$'\n'"EOF${u}x"$'\ngit push --force\nEOF'
    test_start "a Unicode space is part of bash's word under $loc: $(printf '%q' "$c")"
    LC_ALL=$loc run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
for c in $'cat <<EOF\t\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\' \n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF >/dev/null\n'"$FP"$'\nEOF\necho done'; do
  test_start "a word ended by a space or a tab still hides its body: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
# Round 9: `#` after `{` or `}` is a word character to bash; read as a comment it hid an opener
# or an open quote, and a later `cat <<Z` hid a push bash runs (oracle RAN). The allowlist
# accepts `#` only at a token start.
for c in $'echo {#} <<\\E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo }#x <<\\E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#} <<E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#} <<\'E\'\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#\'\ncat <<Z\n\'\ngit push --force\nZ' \
         $'echo }#\'\ncat <<Z\n\'\ngit push --force\nZ' \
         $'echo {#"\ncat <<Z\n"\ngit push --force\nZ' \
         $'echo a{#\'\ncat <<Z\n\'\ngit push --force\nZ'; do
  test_start "a # inside a word is not a comment: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a variable in a word or a double quote does not end the stripping: the body stays hidden"
run_gate $'D=/tmp; cat > "$D/n.md" <<\'EOF\'\n'"$FP"$'\nEOF\necho ${D} $1 done'
assert_exit "$RC" "0" "passes"
test_start "a command substitution before the opener ends the stripping (allowlist cost: read in full)"
run_gate $'cat > $(echo n.md) <<\'EOF\'\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
test_start "a closing quote is not an opening quote: echo it's <<EOF 'x' opens no phantom (push read)"
run_gate $'echo it\'s <<EOF \'x\'\ngit push --force'
assert_exit "$RC" "2" "blocked"
# A delimiter bash accepts opens a real body: a digit, a path, an escaped backslash before it.
for shape in \
  $'cat <<1 > n.md\n'"$FP"$'\n1\necho done' \
  $'cat <</dev/null > n.md\n'"$FP"$'\n/dev/null\necho done' \
  $'echo \\\\<<EOF > n.md\n'"$FP"$'\nEOF\necho done' \
  ; do
  test_start "a delimiter outside [A-Za-z_][A-Za-z0-9_.-]*: the body is read in full (allowlist cost: read in full): $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"
done
# An escaped character is inert, not deleted: a real heredoc after `\#` or `\$` is still a heredoc.
test_start "an escape before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'cat \\#<<EOF > n.md\nrun '"$FP"$' now\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# The shell word behind a prefix the shell steps over.
for shape in \
  $'SH=bash; env $SH <<EOF\n'"$FP"$'\nEOF' \
  $'exec $SH <<EOF\n'"$FP"$'\nEOF' \
  $'time $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nohup $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nice -n5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nice -n 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'timeout 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'command $SH <<EOF\n'"$FP"$'\nEOF' \
  $'($SH) <<EOF\n'"$FP"$'\nEOF' \
  $'FOO=1 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'FOO=$X $SH <<EOF\n'"$FP"$'\nEOF' \
  $'</dev/null $SH <<EOF\n'"$FP"$'\nEOF' \
  $'<<EOF $SH -s\n'"$FP"$'\nEOF' \
  $'${SH:-bash} <<EOF\n'"$FP"$'\nEOF' \
  $'${ARR[0]} <<EOF\n'"$FP"$'\nEOF' \
  $'builtin source /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'command . /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'sudo -u root $SH <<EOF\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# ── lens round 3 (2026-10-03): an array literal is words, not redirections; env/timeout/exec
# options that take an argument take it; `{` opens a group.
for pre in 'x=(1<<2)' 'declare -a x=(1<<2)' 'a=(b<<2 c)' 'x=(<<2)' 'x+=(1<<2)'; do
  test_start "not an opener: $(printf '%q' "$pre") — a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for shape in \
  $'SH=bash; env -u X $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; env -C /tmp $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; timeout -s KILL 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; timeout -k 2 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; exec -a name $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; { $SH <<EOF\n'"$FP"$'\nEOF\n}' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# Round 3 final: a quote that runs across lines is text to its close; an escaped delimiter
# character is that character; a nested group walks back to ITS opener; more prefixes.
for pre in $'echo "a <<2\nb"' $'echo \'x <<1 y\nz\'' $'git commit -m "shift 1<<2\nbody"'; do
  test_start "a quote spanning lines opens no heredoc: $(printf '%q' "${pre%%$'\n'*}") — a bare force-push after it blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a quote spanning lines before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'echo "a\nb" <<EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
test_start "text between a substitution's close and the outer quote is quoted: \"\$(echo a)<<EOF\" opens nothing"
run_gate $'echo "$(echo "a")<<EOF"\ngit push --force'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "the commit-message shape closing with text after )\" on the last line reads that text"
run_gate $'git commit -m "$(cat <<\'EOF\'\nnote\nEOF\n)" && git push --force'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
# Round 4: an escaped quote inside a multi-line quote is not its close; a delimiter may carry
# more than one escape; stdbuf's -o/-i/-e take an argument.
for pre in $'echo "a\n\\" x <<2\n"' $'git commit -m "fix\nhe said \\"x\\" and 1<<2\nend"' $'echo $\'a\n\\\' <<2\n\''; do
  test_start "an escaped quote on a continuation line is not the close: $(printf '%q' "${pre%%$'\n'*}") — the push after blocks"
  run_gate "$pre"$' ; git push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "escaped quotes in a quote before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'echo "a\n\\"x\\" b" <<EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
for d in '\#\#' '\*\*' '\#\!' '\?\?' '\#a\#' '\#\#\#'; do
  plain="${d//\\/}"
  test_start "a delimiter with several escapes <<$d closes at $plain; the push after it blocks"
  run_gate "cat <<$d"$'\nfoo\n'"$plain"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "a delimiter with several escapes <<$d opens no body: its text is read (fail-closed, round 5)"
  run_gate "cat <<$d > n.md"$'\n'"$FP"$'\n'"$plain"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
# An escaped backslash in the delimiter is a literal backslash: `<<\\E` closes at `\E`.
for pair in '\\E:\E' '\\#:\#' '\\\\#:\\#'; do
  d="${pair%%:*}"; cl="${pair#*:}"
  test_start "an escaped backslash in the delimiter is literal: <<$d closes at $cl; the push after blocks"
  run_gate "cat <<$d"$'\nfoo\n'"$cl"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "an escaped backslash in the delimiter: <<$d opens no body (fail-closed, round 5)"
  run_gate "cat <<$d > n.md"$'\n'"$FP"$'\n'"$cl"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
test_start "a shell behind a prefix feeds the body: stdbuf -o 0 \$SH"
run_gate $'SH=bash; stdbuf -o 0 $SH <<EOF\n'"$FP"$'\nEOF'; assert_exit "$RC" "2" "blocked"
test_start "stdbuf's argument is not the command word: stdbuf -o \$N cat <<EOF is text"
run_gate $'stdbuf -o $N cat <<EOF\nrun '"$FP"$' now\nEOF'; assert_exit "$RC" "0" "passes"
for d in '#' '.' '!' '~' '*' '#x'; do
  test_start "an escaped delimiter <<\\$d: the push after its closing line blocks"
  run_gate "cat <<\\$d"$'\nbody\n'"$d"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "an escaped punctuation delimiter <<\\$d: the body is read in full (allowlist cost: read in full)"
  run_gate "cat <<\\$d > n.md"$'\n'"$FP"$'\n'"$d"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
test_start "a whole-escaped plain delimiter <<\\EOF is read with certainty and hides its body"
run_gate $'cat <<\\EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "0" "passes"
# One rule away from the unclosed-body rule: a misread delimiter whose misreading happens to
# appear as a LATER line would close late and swallow the lines between. Without the
# "uncertain word opens no body" rule, `<<\#\#` would be read as `__` and the `__` line below
# would close it after the push.
test_start "an uncertain delimiter opens no body even when its misreading appears as a later line"
run_gate $'cat <<\\#\\#\nfoo\n##\ngit push --force\n__'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "an uncertain quoted-piece delimiter opens no body even when its misreading appears later"
run_gate $'cat <<E\'O\'F\nfoo\nEOF\ngit push --force\nEO'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "a body that never closes is not stripped: the wrapped payload in it is read (fail-closed)"
run_gate $'cat <<NEVER > n.md\n'"$FP"$'\nstill body'
assert_exit "$RC" "2" "blocked"
test_start "a body that never closes: a bare force-push inside it is read (fail-closed)"
run_gate $'cat <<NEVER > n.md\ngit push --force'
assert_exit "$RC" "2" "blocked"
# Round 5's four shapes: each misread delimiter had opened a body that never closed.
for shape in \
  $'cat <<\\-\\-\nfoo\n--\ngit push --force' \
  $'cat <<\\-x\nfoo\n-x\ngit push --force' \
  $'cat <<\\#\\ \\#\nfoo\n# #\ngit push --force' \
  $'cat <<\\#\'#\'\nfoo\n##\ngit push --force' \
  $'cat <<"E\\OF"\nfoo\nE\\OF\ngit push --force' \
  $'cat <<"\\#\\#"\nfoo\n\\#\\#\ngit push --force' \
  $'cat <<\\#"\\#"\nfoo\n#\\#\ngit push --force' \
  ; do
  test_start "a delimiter the gate cannot read with certainty opens no body: $(printf '%q' "${shape%%$'\n'*}") — the push blocks"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a nested group walks back to its own opener: ( bash / ( cat ) / ) <<EOF feeds the body"
run_gate $'( bash\n( cat )\n) <<EOF\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
for shape in \
  $'SH=bash; ionice -c 2 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; ! $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; if $SH <<EOF\n'"$FP"$'\nEOF\nthen :; fi' \
  $'SH=bash; 2>/dev/null $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; { $SH; } <<EOF\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The option that takes an argument takes it: the word after `-u` is not the command.
for shape in \
  $'ionice -c $C cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'env -u $V cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'timeout -s $SIG 5 cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -u $U tee /etc/x <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -u "$USER" tee /etc/x <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -n -u $U cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -E cat $F <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo tee $OUT <<EOF\nrun '"$FP"$' now\nEOF' \
  $'nice -n $N cat <<EOF\nrun '"$FP"$' now\nEOF' \
  ; do
  test_start "a variable that is an option's argument is not a shell: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "0" "passes"
done

# ── a flag belongs to ITS command (2026-09-28): `git push … && git worktree remove --force x`
# was blocked RED as a force-push, because `push[[:space:]].*--force` ran past the `&&`.
# The flag must sit in the same simple command as the verb; every real shape still blocks.
rm -f "$(care_path)"
test_start "a --force on a LATER command is not a force-push"
run_gate "git push -q origin main && git worktree remove --force /tmp/wt"
assert_not_contains "$ERR" "force-push" "stderr names no force-push"
test_start "a -f on a later command is not a force-push"
run_gate "git push origin main; rm -f /tmp/x.log"
assert_not_contains "$ERR" "force-push" "stderr names no force-push"
test_start "a --hard on a later command is not reset-hard"
run_gate "git reset HEAD~0 && git checkout --hard-to-guess-branch-name || true"
assert_not_contains "$ERR" "reset-hard" "stderr names no reset-hard"
test_start "an --amend on a later command is not commit-amend"
run_gate "git commit -m x | tee log; echo --amend"
assert_not_contains "$ERR" "commit-amend" "stderr names no commit-amend"
test_start "control: a force-push AFTER an unrelated command still blocks"
run_gate "git worktree remove --force /tmp/wt && git push --force origin main"
assert_exit "$RC" "2" "blocked"
test_start "control: --force at the end of the same push still blocks"
run_gate "git push origin main --force && echo done"
assert_exit "$RC" "2" "blocked"
test_start "control: -f in the middle of the same push still blocks"
run_gate "git push -f origin main | tee log"
assert_exit "$RC" "2" "blocked"
test_start "control: --force-with-lease=ref:sha still blocks"
run_gate "git push --force-with-lease=main:abc123 origin main"
assert_exit "$RC" "2" "blocked"
test_start "control: reset --hard in the same command still blocks"
run_gate "git reset -q --hard HEAD~1; echo ok"
assert_exit "$RC" "2" "blocked"

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
