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

test_start "a spend run held past the walks' clock still spends under the key it reserved (the commit review on 177319d)"
# The blocking run's table walk is cut on the clock as parser-budget; the spend run's is
# not: a cut there would key parser-budget, read the red file, and leave the yellow
# reservation for its 5 minutes. A grep on PATH holds the first table grep 3 s.
SLOWG="$TEST_TMP/slowgrep-consume"; mkdir -p "$SLOWG"; REALGREP="$(command -v grep)"
cat > "$SLOWG/grep" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-qE" ] && [ ! -e "$TEST_TMP/slowgrep-consume.once" ]; then : > "$TEST_TMP/slowgrep-consume.once"; sleep 3; fi
exec "$REALGREP" "\$@"
EOF
chmod +x "$SLOWG/grep"
rm -f "$TEST_TMP/slowgrep-consume.once"
seed_reserved "$(care_path)" git-push default 0 "git push origin main"
ERR="$(make_bash_tool_input "git push origin main" | PATH="$SLOWG:$PATH" bash "$GATE" consume 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "consume never blocks"
assert_eq "$(read_care '.gate_cleared["git-push"].until // "absent"')" "absent" "the reservation is spent, not left"
assert_contains "$ERR" "is spent" "the spend is spoken"
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

# ── The token file: a command that names it may only READ it (10-19) ──────────────
# The writer net was a list of verbs and redirects, and lens 8 on a19b8a0 walked past it with
# sed -i, >|, tee -a: the denylist shape that lost twice on 09-28. Now an allowlist: when a
# command names care-redclear.json, every command word in it must be a plain reader and no
# redirect may point into the file. Anything else is refused, the honest cost included.
test_start "redclear: sed -i rewrites it in place is refused"
run_gate 'sed -i s/a/b/ /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "sed -i rewrites it in place"
test_start "redclear: perl -pi rewrites it in place is refused"
run_gate 'perl -pi -e s/a/b/ /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "perl -pi rewrites it in place"
test_start "redclear: a clobber redirect is refused"
run_gate 'echo x >|/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a clobber redirect"
test_start "redclear: an &> redirect is refused"
run_gate 'echo x &>/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an &> redirect"
test_start "redclear: a >& redirect is refused"
run_gate 'echo x >&/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a >& redirect"
test_start "redclear: a read-write open is refused"
run_gate 'cat <>/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a read-write open"
test_start "redclear: tee with a flag before the file is refused"
run_gate 'echo {} | tee -a /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "tee with a flag before the file"
test_start "redclear: a plain rm is refused"
run_gate 'rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a plain rm"
test_start "redclear: the name handed to xargs is refused"
run_gate 'echo /x/.maude/plugin/care-redclear.json | xargs rm'
assert_exit "$RC" "2" "the name handed to xargs"
test_start "redclear: the name handed out of a substitution is refused"
run_gate 'rm $(echo /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "the name handed out of a substitution"
test_start "redclear: the name parked in a variable is refused"
run_gate 'F=/x/.maude/plugin/care-redclear.json; sed -i s/a/b/ $F'
assert_exit "$RC" "2" "the name parked in a variable"
test_start "redclear: a reader redirected into it is refused"
run_gate 'cat /tmp/t.json > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a reader redirected into it"
test_start "redclear: an interpreter is refused"
run_gate 'python3 -c "open('\''/x/.maude/plugin/care-redclear.json'\'','\''w'\'').write('\''x'\'')"'
assert_exit "$RC" "2" "an interpreter"
test_start "redclear: a reader wrapping a writer in a substitution is refused"
run_gate 'cat $(sed -i s/a/b/ /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "the writer inside the reader's substitution"
test_start "redclear: a reader wrapping a writer in backticks is refused"
run_gate 'cat `rm /x/.maude/plugin/care-redclear.json`'
assert_exit "$RC" "2" "the writer inside backticks"
test_start "redclear: a read beside other work is refused (split it into its own call)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; rm -f /tmp/x'
assert_exit "$RC" "2" "a read and an rm in one command"
test_start "redclear: jq reads it still passes"
run_gate 'jq . /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "jq reads it"
test_start "redclear: a read piped to a reader still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json | jq .'
assert_exit "$RC" "0" "a read piped to a reader"
test_start "redclear: two reads still passes"
run_gate 'ls -la /x/.maude/plugin/care-redclear.json; wc -c /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "two reads"
test_start "redclear: a checksum still passes"
run_gate 'cksum /x/.maude/plugin/care-redclear.json; shasum -a 256 /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a checksum"
test_start "redclear: a test still passes"
run_gate 'test -s /x/.maude/plugin/care-redclear.json && echo yes'
assert_exit "$RC" "0" "a test"
test_start "redclear: a read redirected elsewhere still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /tmp/copy.json'
assert_exit "$RC" "0" "a read redirected elsewhere"
test_start "redclear: a read with stderr to null still passes"
run_gate 'grep -c until /x/.maude/plugin/care-redclear.json 2>/dev/null'
assert_exit "$RC" "0" "a read with stderr to null"
# A read is still a read when it wears the shell's grammar: an fd dup, a cd, a keyword,
# an assignment prefix (lens 9 on d247dba, M1). A keyword is skipped to the word after it.
test_start "redclear: an fd dup is not a command word still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json 2>&1 | head'
assert_exit "$RC" "0" "an fd dup is not a command word"
test_start "redclear: a read sent to stderr still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >&2'
assert_exit "$RC" "0" "a read sent to stderr"
test_start "redclear: a cd before the read still passes"
run_gate 'cd /x/.maude/plugin && cat care-redclear.json'
assert_exit "$RC" "0" "a cd before the read"
test_start "redclear: a read inside if still passes"
run_gate 'if [ -f /x/.maude/plugin/care-redclear.json ]; then cat /x/.maude/plugin/care-redclear.json; fi'
assert_exit "$RC" "0" "a read inside if"
test_start "redclear: a read inside a for loop is refused since round 14 (the cost, owned: for binds a name)"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do cat $f; done'
assert_exit "$RC" "2" "a read inside a for loop (refused: for binds a name)"
test_start "redclear: an assignment prefix on a reader still passes"
run_gate 'LC_ALL=C cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "an assignment prefix on a reader"
test_start "redclear: the name parked in a variable, then read still passes"
run_gate 'f=/x/.maude/plugin/care-redclear.json; cat $f'
assert_exit "$RC" "0" "the name parked in a variable, then read"
test_start "redclear: a write inside a for loop (a keyword is skipped, not allowed) is refused"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do rm $f; done'
assert_exit "$RC" "2" "a write inside a for loop (a keyword is skipped, not allowed)"
test_start "redclear: a write after then is refused"
run_gate 'if true; then rm /x/.maude/plugin/care-redclear.json; fi'
assert_exit "$RC" "2" "a write after then"
test_start "redclear: an assignment prefix on a writer is refused"
run_gate 'LC_ALL=C rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an assignment prefix on a writer"
test_start "redclear: a read behind time still passes"
run_gate 'time cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a read behind time"
test_start "redclear: a write behind time is refused"
run_gate 'time rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a write behind time"
# Skipping an assignment let the name ride a variable into a redirect: a write redirect
# must point at a plain name (a security review of 4e4f09d).
test_start "redclear: the name parked in a variable, then written by a redirect is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; echo x > $f'
assert_exit "$RC" "2" "the name parked in a variable, then written by a redirect"
test_start "redclear: a redirect into the loop variable is refused"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do echo x > $f; done'
assert_exit "$RC" "2" "a redirect into the loop variable"
test_start "redclear: an append into the variable is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; printf x >> $f'
assert_exit "$RC" "2" "an append into the variable"
test_start "redclear: a read-write redirect into the variable is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; cat $f 1<>$f'
assert_exit "$RC" "2" "a read-write redirect into the variable"
test_start "redclear: a redirect into a substitution is refused"
run_gate 'echo x > `echo /x/.maude/plugin/care-redclear.json`'
assert_exit "$RC" "2" "a redirect into a substitution"
test_start "redclear: a redirect into a dollar substitution is refused"
run_gate 'echo x > $(echo /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "a redirect into a dollar substitution"
test_start "redclear: a redirect into a glob is refused"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /x/.maude/plugin/care-red*'
assert_exit "$RC" "2" "a redirect into a glob"
test_start "redclear: a read copied to a plain file still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /tmp/copy'
assert_exit "$RC" "0" "a read copied to a plain file"
test_start "redclear: a read sent to /dev/null still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >/dev/null 2>&1'
assert_exit "$RC" "0" "a read sent to /dev/null"
test_start "redclear: a read with stdout closed still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >&-'
assert_exit "$RC" "0" "a read with stdout closed"
test_start "redclear: the cost, named: a one-line commit message that spells the file is refused, and the refusal says why"
run_gate 'git commit -m "the gate reads care-redclear.json"'
assert_exit "$RC" "2" "a commit message naming the token file"
assert_contains "$ERR" "may only read it" "the refusal names the rule, not a write"

# lens 2 on the port (2026-11-03): spellings the full-name check let through, reads it refused
test_start "redclear: an uppercase spelling is refused"
run_gate 'echo x > /x/.maude/plugin/CARE-REDCLEAR.JSON'
assert_exit "$RC" "2" "an uppercase spelling is refused"
test_start "redclear: a backslash inside the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-red\\clear.json'
assert_exit "$RC" "2" "a backslash inside the name is refused"
test_start "redclear: an ANSI-C byte in the name is refused"
run_gate 'echo x > $'"'"'/x/.maude/plugin/care-redclear.js\\x6fn'"'"''
assert_exit "$RC" "2" "an ANSI-C byte in the name is refused"
test_start "redclear: an empty expansion inside the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-redclear.jso${e}n'
assert_exit "$RC" "2" "an empty expansion inside the name is refused"
test_start "redclear: the stem parked in a variable, then the name built, is refused"
run_gate 'a=care-redclear; echo x > /x/.maude/plugin/$a.json'
assert_exit "$RC" "2" "the stem parked in a variable, then the name built, is refused"
test_start "redclear: a one-character glob in the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-redclear.js?n'
assert_exit "$RC" "2" "a one-character glob in the name is refused"
test_start "redclear: fallocate is not a reader though it spells cat (the allowlist is anchored)"
run_gate 'fallocate -l 0 /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "fallocate is not a reader though it spells cat (the allowlist is anchored)"
test_start "redclear: a read copied into a quoted path is refused (the cost, named)"
run_gate 'cat /x/.maude/plugin/care-redclear.json > "/tmp/a b"'
assert_exit "$RC" "2" "a read copied into a quoted path is refused (the cost, named)"
test_start "redclear: a quoted redirect into the file is refused"
run_gate 'echo x > "/x/.maude/plugin/care-redclear.json"'
assert_exit "$RC" "2" "a quoted redirect into the file is refused"
test_start "redclear: a negated read still passes"
run_gate '! cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a negated read still passes"
test_start "redclear: a read inside case still passes"
run_gate 'case x in x) cat /x/.maude/plugin/care-redclear.json;; esac'
assert_exit "$RC" "0" "a read inside case still passes"
test_start "redclear: a [[ test still passes"
run_gate '[[ -f /x/.maude/plugin/care-redclear.json ]] && echo yes'
assert_exit "$RC" "0" "a [[ test still passes"
test_start "redclear: a read or true still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json || true'
assert_exit "$RC" "0" "a read or true still passes"
test_start "redclear: a jq filter with a pipe still passes"
run_gate 'jq -r '"'"'.gate_cleared | keys[]'"'"' /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a jq filter with a pipe still passes"
test_start "redclear: a grep for a > still passes"
run_gate 'grep '"'"'>'"'"' /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a grep for a > still passes"
test_start "redclear: sha256sum still passes"   # portability-name-only: the gate reads the name, nothing runs it
run_gate 'sha256sum /x/.maude/plugin/care-redclear.json'   # portability-name-only
assert_exit "$RC" "0" "sha256sum still passes"   # portability-name-only

# the commit security review on fd6851e (2026-11-03): three parser-differential seams, closed by the marked skeleton
test_start "redclear: a quoted name right after the directory is refused"
run_gate 'echo x > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a quoted name right after the directory is refused"
test_start "redclear: a quoted command word before the file is refused"
run_gate '"rm" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a quoted command word before the file is refused"
test_start "redclear: an erased span in command position cannot hide a writer"
run_gate '""cat /tmp/x; "rm" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an erased span in command position cannot hide a writer"
test_start "redclear: an expansion inside the stem is refused"
run_gate 'echo x > /x/.maude/plugin/care-red${x}clear.json'
assert_exit "$RC" "2" "an expansion inside the stem is refused"
test_start "redclear: a brace inside the stem is refused"
run_gate 'echo x > /x/.maude/plugin/care-red{clear,x}.json'
assert_exit "$RC" "2" "a brace inside the stem is refused"
test_start "redclear: a quoted fragment of the stem is refused"
run_gate 'echo x > /x/.maude/plugin/"care-red"clear.json'
assert_exit "$RC" "2" "a quoted fragment of the stem is refused"
test_start "redclear: a quoted span in a read's own options still passes"
run_gate 'grep -c "until" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a quoted span in a read's own options still passes"
test_start "redclear: a quoted plain path beside a read of another file still passes"
run_gate 'cat /x/.maude/plugin/"care.json"'
assert_exit "$RC" "0" "a quoted plain path beside a read of another file still passes"

# the review on b18802e (2026-11-03): a substitution inside a quoted span is walked, marked or not
test_start "redclear: a writer inside a quoted substitution is refused"
run_gate 'echo "$(rm /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "2" "a writer inside a quoted substitution is refused"
test_start "redclear: a writer inside quoted backticks is refused"
run_gate 'echo "`rm /x/.maude/plugin/care-redclear.json`"'
assert_exit "$RC" "2" "a writer inside quoted backticks is refused"
test_start "redclear: a writer inside a quoted substitution behind a reader is refused"
run_gate 'cat "$(sed -i s/a/b/ /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "2" "a writer inside a quoted substitution behind a reader is refused"
test_start "redclear: a read inside a quoted substitution still passes"
run_gate 'echo "$(cat /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "0" "a read inside a quoted substitution still passes"

# round 5 (2026-11-03): lens 3 on fd6851e and the review on a3ece74
test_start "redclear: a quoted command word followed by words is a writer (review on a3ece74)"
run_gate '"rm" cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a quoted command word followed by words is a writer (review on a3ece74)"
test_start "redclear: an empty quote before a reader and the file is refused"
run_gate '"" cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an empty quote before a reader and the file is refused"
test_start "redclear: a colon redirected into a partly quoted name is refused (lens 3 B1)"
run_gate ': > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a colon redirected into a partly quoted name is refused (lens 3 B1)"
test_start "redclear: a name quoted from the middle is refused (lens 3 B1)"
run_gate 'echo x > /x/.maude/plugin/care-"redclear.json"'
assert_exit "$RC" "2" "a name quoted from the middle is refused (lens 3 B1)"
test_start "redclear: a brace inside the stem fed to tee is refused (lens 3 B2)"
run_gate 'echo x | tee /x/.maude/plugin/care-{redclear,x}.json'
assert_exit "$RC" "2" "a brace inside the stem fed to tee is refused (lens 3 B2)"
test_start "redclear: rm of a brace inside the stem is refused (lens 3 B2)"
run_gate 'rm /x/.maude/plugin/care-{redclear,x}.json'
assert_exit "$RC" "2" "rm of a brace inside the stem is refused (lens 3 B2)"
test_start "redclear: a stem split across two variables is refused (lens 3 B2)"
run_gate 'a=care-red; b=clear; echo x > /x/.maude/plugin/$a$b.json'
assert_exit "$RC" "2" "a stem split across two variables is refused (lens 3 B2)"
test_start "redclear: a glob inside the stem is refused (lens 3 B2)"
run_gate 'echo x > /x/.maude/plugin/care-redcl?ar.json'
assert_exit "$RC" "2" "a glob inside the stem is refused (lens 3 B2)"
test_start "redclear: a bracket inside the stem is refused (lens 3 B2)"
run_gate 'echo x > /x/.maude/plugin/care-red[c]lear.json'
assert_exit "$RC" "2" "a bracket inside the stem is refused (lens 3 B2)"
test_start "redclear: a write inside a bash-fed heredoc is refused (the content view stands in)"
run_gate 'bash <<'"'"'EOF'"'"'
echo x > /x/.maude/plugin/care-redclear.json
EOF'
assert_exit "$RC" "2" "a write inside a bash-fed heredoc is refused (the content view stands in)"
test_start "redclear: a checksum piped to cut still passes"   # portability-name-only
run_gate 'sha256sum /x/.maude/plugin/care-redclear.json | cut -c1-8'   # portability-name-only
assert_exit "$RC" "0" "a checksum piped to cut still passes"   # portability-name-only
test_start "redclear: a read piped to nl still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json | nl'
assert_exit "$RC" "0" "a read piped to nl still passes"
test_start "redclear: sort -o into the file is refused (sort is no reader)"
run_gate 'sort -o /x/.maude/plugin/care-redclear.json /tmp/forged'
assert_exit "$RC" "2" "sort -o into the file is refused (sort is no reader)"
test_start "redclear: uniq with the file as its second operand is refused"
run_gate 'uniq /tmp/forged /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "uniq with the file as its second operand is refused"
test_start "redclear: xxd -r into the file is refused"
run_gate 'xxd -r /tmp/forged.hex /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "xxd -r into the file is refused"
test_start "redclear: less with a log file is refused (less is no reader)"
run_gate 'less -o /x/.maude/plugin/care-redclear.json /tmp/forged'
assert_exit "$RC" "2" "less with a log file is refused (less is no reader)"
test_start "redclear: a read loop over the file is refused since round 12 (the cost, owned: read is a binding builtin)"
run_gate 'while read -r l; do echo "$l"; done < /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a read loop over the file is refused since round 12 (the cost, owned: read is a binding builtin)"
test_start "redclear: a read inside a quoted substitution still passes (the lone marker)"
run_gate 'echo "$(cat /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "0" "a read inside a quoted substitution still passes (the lone marker)"

# round 7 (2026-11-03): lens 4 on ae87414, a name assembled across statement seams
test_start "redclear: the stem split across an assignment seam, written by cat, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; cat /tmp/f > ${p}clear.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, written by cat, is refused (lens 4)"
test_start "redclear: the stem split across an assignment seam, replaced by mv, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; mv /tmp/forged.json ${p}clear.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, replaced by mv, is refused (lens 4)"
test_start "redclear: the stem split across an assignment seam, fed to tee, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; tee ${p}clear.json < /tmp/forged.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, fed to tee, is refused (lens 4)"
test_start "redclear: a cd into the directory, then a split name, is refused (lens 4)"
run_gate 'cd /x/.maude/plugin/; p=care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a cd into the directory, then a split name, is refused (lens 4)"
test_start "redclear: two variables making the name are refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; q=clear.json; echo x > $p$q'
assert_exit "$RC" "2" "two variables making the name are refused (lens 4)"
test_start "redclear: the directory itself split across variables is refused (lens 4)"
run_gate 'd=/x/.maude/plug; p=care-red; echo x > ${d}in/${p}clear.json'
assert_exit "$RC" "2" "the directory itself split across variables is refused (lens 4)"
test_start "redclear: a chained assignment making the directory is refused (lens 4)"
run_gate 'a=/x; b=$a/.maude; c=$b/plugin; echo x > $c/care-redclear.json'
assert_exit "$RC" "2" "a chained assignment making the directory is refused (lens 4)"
test_start "redclear: a split name read by cat still passes (lens 4's companion)"
run_gate 'p=/x/.maude/plugin/care-red; cat ${p}clear.json'
assert_exit "$RC" "0" "a split name read by cat still passes (lens 4's companion)"
test_start "redclear: the whole name in a variable read by cat still passes (lens 4's companion)"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p'
assert_exit "$RC" "0" "the whole name in a variable read by cat still passes (lens 4's companion)"
test_start "redclear: a cd into the directory then a plain read still passes"
run_gate 'cd /x/.maude/plugin/ && cat care-redclear.json'
assert_exit "$RC" "0" "a cd into the directory then a plain read still passes"

# round 8 (2026-11-03): the review on e69db43, the fold only ever adds a match
test_start "redclear: a backtick-built word in the directory is refused on the raw view (review on e69db43)"
run_gate 'echo x > /x/.maude/plugin/`cat /tmp/n`'
assert_exit "$RC" "2" "a backtick-built word in the directory is refused on the raw view (review on e69db43)"
test_start "redclear: a self-referential value in braces ends the fold and is refused"
run_gate 'p=${p}x; echo x > /x/.maude/plugin/${p}'
assert_exit "$RC" "2" "a self-referential value in braces ends the fold and is refused"
test_start "redclear: a value holding a substitution is not folded, and its use in the directory is refused"
run_gate 'p=$(echo care-red); echo x > /x/.maude/plugin/${p}clear.json'
assert_exit "$RC" "2" "a value holding a substitution is not folded, and its use in the directory is refused"
test_start "redclear: a self-referential value ends the fold and is refused"
run_gate 'p=${p}x; echo x > /x/.maude/plugin/$p'
assert_exit "$RC" "2" "a self-referential value ends the fold and is refused"
test_start "redclear: more than 64 assignments is refused outright"
run_gate 'v0=x; v1=x; v2=x; v3=x; v4=x; v5=x; v6=x; v7=x; v8=x; v9=x; v10=x; v11=x; v12=x; v13=x; v14=x; v15=x; v16=x; v17=x; v18=x; v19=x; v20=x; v21=x; v22=x; v23=x; v24=x; v25=x; v26=x; v27=x; v28=x; v29=x; v30=x; v31=x; v32=x; v33=x; v34=x; v35=x; v36=x; v37=x; v38=x; v39=x; v40=x; v41=x; v42=x; v43=x; v44=x; v45=x; v46=x; v47=x; v48=x; v49=x; v50=x; v51=x; v52=x; v53=x; v54=x; v55=x; v56=x; v57=x; v58=x; v59=x; v60=x; v61=x; v62=x; v63=x; v64=x; v65=x; v66=x; v67=x; v68=x; v69=x; echo x > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "more than 64 assignments is refused outright"
test_start "redclear: a fold that grows past its length is refused outright"
run_gate 'a=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; b=$a$a$a$a$a$a$a$a; c=$b$b$b$b$b$b$b$b; d=$c$c$c$c$c$c$c$c; e=$d$d$d$d$d$d$d$d; echo x > /x/.maude/plugin/care-red$e'
assert_exit "$RC" "2" "a fold that grows past its length is refused outright"
test_start "redclear: a cd into the directory then an unset variable in the name is refused"
run_gate 'cd /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "a cd into the directory then an unset variable in the name is refused"

# round 9 (2026-11-03): the review on adf94aa, the cd fold fails closed
test_start "redclear: cd with an option before the directory is refused (review on adf94aa)"
run_gate 'cd -P /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "cd with an option before the directory is refused (review on adf94aa)"
test_start "redclear: pushd into the directory is cd"
run_gate 'pushd /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "pushd into the directory is cd"
test_start "redclear: a chain of relative cds into the directory is refused"
run_gate 'cd /x; cd .maude; cd plugin; echo x > care-red${q}'
assert_exit "$RC" "2" "a chain of relative cds into the directory is refused"
test_start "redclear: a cd the fold cannot read, then a built relative name, is refused outright"
run_gate 'cd /x/.maude; cd $(cat /tmp/d); echo x > care-red${q}'
assert_exit "$RC" "2" "a cd the fold cannot read, then a built relative name, is refused outright"
test_start "redclear: a popd then a built relative name is refused outright"
run_gate 'cd /x/.maude/plugin/; popd; echo x > care-red${q}'
assert_exit "$RC" "2" "a popd then a built relative name is refused outright"
test_start "redclear: a cd the fold cannot read, then an absolute read, still passes"
run_gate 'cd $(cat /tmp/d) && cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a cd the fold cannot read, then an absolute read, still passes"
test_start "redclear: cd -- then the directory, then a plain read, still passes"
run_gate 'cd -- /x/.maude/plugin/ && cat care-redclear.json'
assert_exit "$RC" "0" "cd -- then the directory, then a plain read, still passes"

# round 10 (2026-11-03): the second review on adf94aa, a stale literal binding never folds
test_start "redclear: a name assigned twice is not folded and its use is refused (second review on adf94aa)"
run_gate 'p=/tmp/safe; p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name assigned twice is not folded and its use is refused (second review on adf94aa)"
test_start "redclear: a name rebound by read is not folded and its use is refused"
run_gate 'p=/tmp/safe; read -r p < /x/.maude/d; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by read is not folded and its use is refused"
test_start "redclear: a name rebound by for is not folded and its use is refused"
run_gate 'p=/tmp/safe; for p in /x/.maude/plugin/care-red; do echo x > ${p}clear.json; done'
assert_exit "$RC" "2" "a name rebound by for is not folded and its use is refused"
test_start "redclear: a name rebound by printf -v is not folded and its use is refused"
run_gate 'p=/tmp/safe; printf -v p %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by printf -v is not folded and its use is refused"
test_start "redclear: a name assigned once, used in a read, still passes"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p && cat $p'
assert_exit "$RC" "0" "a name assigned once, used in a read, still passes"
test_start "redclear: a reassigned name in a command that never spells .maude is not the gate's"
run_gate 'x=1; x=2; echo $x > /tmp/out'
assert_exit "$RC" "0" "a reassigned name in a command that never spells .maude is not the gate's"

# round 11 (2026-11-03): the review on b865c4d, the fold fails closed by construction
test_start "redclear: a name grown by += is not folded and its use is refused (review on b865c4d)"
run_gate 'p=/tmp/safe; p+=x; echo x > ${p}clear.json; cat /x/.maude/d'
assert_exit "$RC" "2" "a name grown by += is not folded and its use is refused (review on b865c4d)"
test_start "redclear: a name rebound by -v glued to it is not folded and its use is refused"
run_gate 'p=/tmp/safe; printf -vp %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by -v glued to it is not folded and its use is refused"
test_start "redclear: a name used inside another assignment's value is checked there too"
run_gate 'p=/tmp/safe; read -r p < /x/.maude/d; q=${p}clear.json; echo x > $q'
assert_exit "$RC" "2" "a name used inside another assignment's value is checked there too"
test_start "redclear: a declare -n in a command that spells .maude ends the fold outright"
run_gate 'declare -n p=q; q=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a declare -n in a command that spells .maude ends the fold outright"
test_start "redclear: a let in a command that spells .maude ends the fold outright"
run_gate 'let i=1; p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a let in a command that spells .maude ends the fold outright"
test_start "redclear: a ${NAME:=} in a command that spells .maude ends the fold outright"
run_gate 'echo ${p:=/x/.maude/plugin/care-red}; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a ${NAME:=} in a command that spells .maude ends the fold outright"
test_start "redclear: a once-assigned name whose value reads another once-assigned name still passes"
run_gate 'd=/x/.maude/plugin/; p=${d}care-redclear.json; cat $p'
assert_exit "$RC" "0" "a once-assigned name whose value reads another once-assigned name still passes"

# round 12 (2026-11-03): the review on 4274bdc, a binding builtin ends the fold
test_start "redclear: a declare by any spelling ends the fold where .maude is spelled (review on 4274bdc)"
run_gate 'declare -x p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a declare by any spelling ends the fold where .maude is spelled (review on 4274bdc)"
test_start "redclear: a binding builtin given a built name ends the fold"
run_gate 'n=p; p=/tmp/safe; printf -v $n %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a binding builtin given a built name ends the fold"
test_start "redclear: a shell-managed name in the token directory is refused"
run_gate 'echo x > /x/.maude/plugin/${REPLY}'
assert_exit "$RC" "2" "a shell-managed name in the token directory is refused"
test_start "redclear: a backslash cannot hide the binding builtin"
run_gate 'p=/tmp/safe; re\\ad -r p < /x/.maude/d; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a backslash cannot hide the binding builtin"
test_start "redclear: a read of the file beside a read builtin is refused (the cost, owned)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; read -r x < /tmp/y; echo $x'
assert_exit "$RC" "2" "a read of the file beside a read builtin is refused (the cost, owned)"
test_start "redclear: a plain read with no binding builtin and no shell-managed name still passes"
run_gate 'd=/x/.maude/plugin/; cat ${d}care-redclear.json | nl'
assert_exit "$RC" "0" "a plain read with no binding builtin and no shell-managed name still passes"

# round 13 (2026-11-03): the review on dd75ced, any directory change fails closed
test_start "redclear: the directory stack cannot reach the token (review on dd75ced)"
run_gate 'pushd /x/.maude/plugin/; pushd /tmp; pushd +1; echo x > care-red${q}'
assert_exit "$RC" "2" "the directory stack cannot reach the token (review on dd75ced)"
test_start "redclear: a bare cd then a built relative name is refused"
run_gate 'cd /x/.maude/plugin/; cd; echo x > care-red${q}'
assert_exit "$RC" "2" "a bare cd then a built relative name is refused"
test_start "redclear: CDPATH then a built relative name is refused"
run_gate 'CDPATH=/x/.maude; cd plugin; echo x > care-red${q}'
assert_exit "$RC" "2" "CDPATH then a built relative name is refused"
test_start "redclear: a cd then a built ABSOLUTE read still passes"
run_gate 'cd /tmp && cat /x/.maude/plugin/care-redclear.json | nl'
assert_exit "$RC" "0" "a cd then a built ABSOLUTE read still passes"

# round 14 (2026-11-03): the second review on dd75ced, any expansion not folded is OVER; continuations joined
test_start "redclear: a backslash-newline inside the stem is joined and refused (review on dd75ced)"
run_gate 'echo x > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a backslash-newline inside the stem is joined and refused (review on dd75ced)"
test_start "redclear: a backslash-newline inside the stem, with a reader, is refused"
run_gate ': > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a backslash-newline inside the stem, with a reader, is refused"
test_start "redclear: a positional parameter in the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-red$1'
assert_exit "$RC" "2" "a positional parameter in the name is refused"
test_start "redclear: a name never assigned here, used in the directory, is refused"
run_gate 'echo x > /x/.maude/plugin/care-red$zz'
assert_exit "$RC" "2" "a name never assigned here, used in the directory, is refused"
test_start "redclear: a for over the name ends the fold"
run_gate 'p=/x/.maude/plugin/care-red; for q in x; do echo x > ${p}clear.json; done'
assert_exit "$RC" "2" "a for over the name ends the fold"
test_start "redclear: a read beside a special parameter is refused (the cost, owned)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; echo $?'
assert_exit "$RC" "2" "a read beside a special parameter is refused (the cost, owned)"
test_start "redclear: a folded literal used in a read still passes"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p'
assert_exit "$RC" "0" "a folded literal used in a read still passes"

# round 15 (2026-11-03): the review on dbd9120, only an odd backslash run continues
test_start "redclear: an escaped backslash before a separator is not a continuation (review on dbd9120)"
run_gate 'echo \\; rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an escaped backslash before a separator is not a continuation (review on dbd9120)"
test_start "redclear: an escaped backslash before a newline is not a continuation"
run_gate 'echo \\
rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an escaped backslash before a newline is not a continuation"
test_start "redclear: a real continuation in the stem is still joined"
run_gate 'echo x > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a real continuation in the stem is still joined"

# round 16 (2026-11-03): the review on 17bdbdd, the join never drops a marker
test_start "redclear: two adjacent quoted spans making the name are refused (review on 17bdbdd)"
run_gate 'echo x > /x/.maude/plugin/'"'"'care-red'"'"''"'"'clear.json'"'"''
assert_exit "$RC" "2" "two adjacent quoted spans making the name are refused (review on 17bdbdd)"
test_start "redclear: two adjacent empty quotes before the name are refused"
run_gate 'echo x > /x/.maude/plugin/'"'"''"'"'""care-redclear.json'
assert_exit "$RC" "2" "two adjacent empty quotes before the name are refused"
test_start "redclear: a name quoted whole, with a marker pair elsewhere, is refused"
run_gate 'echo '"'"''"'"' '"'"''"'"' > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a name quoted whole, with a marker pair elsewhere, is refused"

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

# ── The red backstops read text as text (2026-10-08, live) ──────────────────────────
# A vault note written through a heredoc carried the clear line for a RED key, and the
# red-self-clear backstop blocked the note: it grepped the quote-stripped command with the
# heredoc BODIES still in it, while every pattern in the table had read a body as data since
# v0.27.0. Documenting the trap sprang it. The two red backstops now read the same
# body-stripped view the table reads, and keep the bodies only where a shell is fed the
# heredoc (that body runs). The plain invocation stays blocked: that is the control.
CR='/x/hooks/scripts/maude-clear-red.sh'

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
printf '%s' "$J" | bash "$GATE" >/dev/null 2>&1; RC2=$?
assert_exit "$RC2" "0" "control: a 120 KB command with no red line passes"
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
