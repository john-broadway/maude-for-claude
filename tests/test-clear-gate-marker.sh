#!/usr/bin/env bash
# Tests for the marker requirement on RED gate clears.
#
# WHY
# ---
# A RED key is meant to be John's hand alone. Until now the only discriminator was
# the --john flag plus a provenance grep in maude-gate.sh for the clear-script's own
# filename, and on 2026-07-30 an audit defeated that by copying the scripts dir and
# renaming the script. The trace entry it wrote was indistinguishable from a real
# authorization.
#
# maude_marker fixes the structural part: a RED clear can require a one-time hash
# chain link that Claude cannot compute. The rule wired here:
#
#   chain configured for the key   -> a valid --marker link is REQUIRED, --john
#                                     alone is refused. Provisioning IS enabling.
#   no chain configured            -> the old --john path still works, but says
#                                     loudly that it is the weak path.
#   MAUDE_MARKER_REQUIRED=1        -> no chain means no clear, period.
#
# The fallback exists because shipping a wall would leave John unable to authorize
# anything tonight. It is loud on purpose: a weak path that is silent is a weak
# path nobody closes.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

CLEAR="$HOOKS_DIR/maude-clear-gate.sh"
CLEARRED="$HOOKS_DIR/maude-clear-red.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# HOME-driven, not env-override-driven: the gate deliberately no longer honours
# MAUDE_MARKER_STATE (that override was the redteam's forgery vector). Tests get
# hermeticity the same way a real house does — their own HOME. MAUDE_MARKER_STATE
# survives here only as the path handed to the CLI's own --state flag, pointed at
# exactly where the gate will look.
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/maude"
export MAUDE_MARKER_STATE="$HOME/.claude/maude/markers.json"
export MAUDE_MARKER_LEDGER="$HOME/.claude/maude/marker-ledger.jsonl"

RED_KEY="sole-copy-target"

# Build a chain for $1 with $2 links; sets LINKS array (LINKS[0] spent first,
# LINKS[n-1] spent FIRST in practice since spending walks down from the top).
# Uses the shipped CLI so the test exercises the real generator.
mkchain() {
  local key="$1" n="$2" out
  out="$(MAUDE_MARKER_GEN_FORCE=1 PYTHONPATH="$ROOT" python3 -m maude_marker gen "$key" "$n" \
        --state "$MAUDE_MARKER_STATE" 2>&1)"
  LINKS=()
  while IFS= read -r l; do LINKS+=("$l"); done < <(printf '%s\n' "$out" | awk '/^ +[0-9]+ +[0-9a-f]{64}$/{print $2}')
}

head_of_chain() {
  jq -r --arg k "$1" '.chains[$k].head' "$MAUDE_MARKER_STATE" 2>/dev/null
}

# ── regression: yellow keys are untouched ──────────────────────────────────

test_start "yellow key still clears with no marker at all"
OUT="$(bash "$CLEAR" git-push 2>&1)"; RC=$?
assert_exit "$RC" "0" "yellow clear"

test_start "yellow key clear does not require --john"
assert_contains "$OUT" "gate cleared" "yellow msg"

# ── no chain configured: the old path, but loud ─────────────────────────────

# These run BEFORE any chain exists. The marker dir must be absent, or the
# marker-house rule (correctly) refuses instead of taking the documented soft path.
rmdir "$HOME/.claude/maude" 2>/dev/null

test_start "red key with no chain and no --john is still refused"
OUT="$(bash "$CLEARRED" "$RED_KEY" 2>&1)"; RC=$?
assert_exit "$RC" "1" "red without john"

test_start "red key with no chain and --john still clears (fallback preserved)"
OUT="$(bash "$CLEARRED" "$RED_KEY" --john 2>&1)"; RC=$?
assert_exit "$RC" "0" "red john fallback"

test_start "the fallback says out loud that it is the weak path"
assert_contains "$OUT" "no marker chain" "weak-path notice"

test_start "MAUDE_MARKER_REQUIRED=1 refuses the unchained --john path"
OUT="$(MAUDE_MARKER_REQUIRED=1 bash "$CLEARRED" "$RED_KEY" --john 2>&1)"; RC=$?
assert_exit "$RC" "1" "required + no chain"

# ── chain configured: provisioning closes the fallback ──────────────────────

mkdir -p "$HOME/.claude/maude"
mkchain "$RED_KEY" 4
test_start "generator produced 4 links"
assert_eq "${#LINKS[@]}" "4" "link count"

test_start "the state file holds no unspent link"
BLOB="$(cat "$MAUDE_MARKER_STATE")"
assert_not_contains "$BLOB" "${LINKS[3]}" "head only"

test_start "with a chain configured, --john ALONE is refused"
OUT="$(bash "$CLEARRED" "$RED_KEY" --john 2>&1)"; RC=$?
assert_exit "$RC" "1" "john alone refused"

test_start "the refusal names the marker as what is missing"
assert_contains "$OUT" "marker" "refusal mentions marker"

test_start "a valid marker link clears the red gate"
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "${LINKS[3]}" 2>&1)"; RC=$?
assert_exit "$RC" "0" "valid marker"

test_start "the red token landed in care-redclear.json"
assert_file_exists "$(redclear_path)" "redclear written"

test_start "replaying the same link is refused"
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "${LINKS[3]}" 2>&1)"; RC=$?
assert_exit "$RC" "1" "replay refused"

test_start "a forward hash derived from the stored head is refused"
H="$(head_of_chain "$RED_KEY")"
FWD="$(printf '%s' "$H" | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest())')"
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "$FWD" 2>&1)"; RC=$?
assert_exit "$RC" "1" "forward hash refused"

test_start "the next link down still works after those refusals"
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "${LINKS[2]}" 2>&1)"; RC=$?
assert_exit "$RC" "0" "next link accepted"

test_start "a link from another key's chain is refused"
mkchain "public-publish" 3
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "${LINKS[2]}" 2>&1)"; RC=$?
assert_exit "$RC" "1" "cross-key refused"

test_start "a malformed marker is refused"
OUT="$(bash "$CLEARRED" "$RED_KEY" --marker "nope" 2>&1)"; RC=$?
assert_exit "$RC" "1" "malformed refused"

test_start "every marker attempt is ledgered, refusals included"
N="$(grep -c . "$MAUDE_MARKER_LEDGER" 2>/dev/null || printf 0)"
[ "$N" -ge 5 ]
assert_exit "$?" "0" "ledger has attempts (got $N)"

test_start "the ledger never contains a raw link"
LBLOB="$(cat "$MAUDE_MARKER_LEDGER" 2>/dev/null)"
assert_not_contains "$LBLOB" "${LINKS[2]}" "no raw token in ledger"

test_start "a refused marker attempt writes no clear token"
rm -f "$(redclear_path)"
bash "$CLEARRED" "$RED_KEY" --marker "$(printf 'a%.0s' $(seq 64))" >/dev/null 2>&1
assert_file_absent "$(redclear_path)" "no token on refusal"

# ── the wrapper: PYTHONPATH must never be the user's problem ────────────────
# Earned the hard way on 2026-07-30: Claude handed John
#   ! python3 -m maude_marker gen sole-copy-target 20
# which fails with "No module named maude_marker" from any shell that has not
# already exported PYTHONPATH. Claude had only ever run it from a shell where he
# had set it himself, so he tested his own convenience and not John's invocation.
# These tests pin the fix so the broken form cannot come back in a message string.

WRAP="$HOOKS_DIR/maude-marker.sh"

test_start "the marker wrapper exists"
assert_file_exists "$WRAP" "wrapper present"

test_start "wrapper runs with PYTHONPATH UNSET (the actual reported bug)"
OUT="$(env -u PYTHONPATH -u CLAUDE_PLUGIN_ROOT bash "$WRAP" status --state "$MAUDE_MARKER_STATE" 2>&1)"
assert_not_contains "$OUT" "No module named" "no import error"

test_start "wrapper status reports a provisioned chain"
assert_contains "$OUT" "sole-copy-target" "status lists the key"

test_start "wrapper passes arguments through to gen"
OUT="$(env -u PYTHONPATH MAUDE_MARKER_GEN_FORCE=1 bash "$WRAP" gen wrapper-probe 3 \
       --state "$TEST_TMP/wrap.json" 2>&1)"
RC=$?
assert_exit "$RC" "0" "wrapper gen"

test_start "wrapper gen actually wrote a chain"
assert_eq "$(jq -r '.chains["wrapper-probe"].remaining' "$TEST_TMP/wrap.json" 2>/dev/null)" "3" "chain remaining"

test_start "wrapper with no args explains itself instead of crashing"
OUT="$(env -u PYTHONPATH bash "$WRAP" 2>&1)"; RC=$?
assert_ne "$RC" "0" "usage exit nonzero"
assert_not_contains "$OUT" "Traceback" "no traceback"

test_start "clear-gate messages never hand the user the bare python3 -m form"
assert_eq "$(grep -c '! python3 -m maude_marker' "$CLEAR" "$CLEARRED" | awk -F: '{t+=$2} END{print t+0}')" "0" "no bare form in messages"

test_start "clear-gate messages point at the wrapper instead"
[ "$(grep -c 'maude-marker.sh' "$CLEARRED")" -ge 1 ]
assert_exit "$?" "0" "wrapper referenced"

test_start "the line gen prints for authorizing is a runnable path"
GOUT="$(env -u PYTHONPATH MAUDE_MARKER_GEN_FORCE=1 bash "$WRAP" gen printcheck 2 \
        --state "$TEST_TMP/pc.json" 2>&1)"
GPATH="$(printf '%s' "$GOUT" | grep -oE '/[^ ]*maude-marker\.sh' | head -1)"
[ -n "$GPATH" ] && [ -x "$GPATH" ]
assert_exit "$?" "0" "printed authorize path is executable (got: ${GPATH:-none})"

test_start "gen's authorize line does not print the bare python3 -m form"
assert_not_contains "$GOUT" "! python3 -m maude_marker" "no bare form in gen output"

# ── The 2026-07-30 redteam: the consumer trusted MY environment ─────────────
# The crypto core held against every attack. The GATE did not: it read the state
# path, the ledger path and the package root straight out of the environment, so
# four one-command forgeries worked with no file edits and no sha256 inversion:
#   A  MAUDE_MARKER_STATE -> a chain Claude minted himself
#   B  MAUDE_MARKER_STATE -> nowhere, so "no chain configured" downgraded to --john
#   C  CLAUDE_PLUGIN_ROOT -> a fake maude_marker whose verify exits 0
#   D  a jq earlier on PATH that reports the chain as absent
# MAUDE_MARKER_STATE existed only for test hermeticity. The testability seam WAS
# the bypass, which is why these tests now drive HOME instead.
#
# The structural fix for B is an enforcement record in care-redclear.json — the one
# file Claude cannot write (harness Edit-deny plus the redclear-write backstop). Once
# a key is enforced there, the gate demands a marker even when it cannot find a
# chain, so making the chain "disappear" no longer downgrades anything.

RT_HOME="$TEST_TMP/rt-home"
mkdir -p "$RT_HOME/.claude/maude"
RT_STATE="$RT_HOME/.claude/maude/markers.json"

# John provisions in his own shell: HOME-derived path, no env override anywhere.
RT_OUT="$(env -u MAUDE_MARKER_STATE -u MAUDE_MARKER_LEDGER -u CLAUDE_PLUGIN_ROOT \
          HOME="$RT_HOME" MAUDE_MARKER_GEN_FORCE=1 bash "$WRAP" gen sole-copy-target 5 2>&1)"
RT_LINKS=()
while IFS= read -r l; do RT_LINKS+=("$l"); done < <(printf '%s\n' "$RT_OUT" | awk '/^ +[0-9]+ +[0-9a-f]{64}$/{print $2}')

test_start "redteam setup: chain provisioned at the HOME-derived path"
assert_eq "${#RT_LINKS[@]}" "5" "5 links"
assert_file_exists "$RT_STATE" "state at HOME path"

# HONEST SCOPE: this record lives beside the state file, which Claude CAN write and
# delete. So attack B is MITIGATED, not closed: deleting markers.json alone no longer
# downgrades the gate, but removing the whole marker directory still would. Closing
# it for real needs a harness deny-rule on that path, which is John's hand by
# construction. The earlier version of this test claimed "where Claude cannot write
# it", which was false — the assertion was checking a file the implementation never
# wrote, so it failed loudly instead of passing a lie. Renamed to what is true.
test_start "gen records a durable enforcement marker beside the state"
assert_file_exists "$RT_HOME/.claude/maude/.marker-enforced" "enforcement record written"

test_start "deleting only markers.json no longer re-opens the --john fallback"
mv "$RT_STATE" "$TEST_TMP/stolen.json"
OUT="$(env -u MAUDE_MARKER_STATE -u CLAUDE_PLUGIN_ROOT HOME="$RT_HOME" \
       bash "$CLEARRED" sole-copy-target --john 2>&1)"; RC=$?
mv "$TEST_TMP/stolen.json" "$RT_STATE"
assert_exit "$RC" "1" "state deletion does not downgrade"

# Claude's own chain, in a place he can write.
ATK="$TEST_TMP/attacker"; mkdir -p "$ATK"
ATK_OUT="$(MAUDE_MARKER_GEN_FORCE=1 bash "$WRAP" gen sole-copy-target 3 --state "$ATK/m.json" 2>&1)"
ATK_LINK="$(printf '%s\n' "$ATK_OUT" | awk '/^ +3 +[0-9a-f]{64}$/{print $2}')"

test_start "ATTACK A: MAUDE_MARKER_STATE redirected to Claude's own chain is REFUSED"
OUT="$(HOME="$RT_HOME" MAUDE_MARKER_STATE="$ATK/m.json" MAUDE_MARKER_LEDGER="$ATK/l.jsonl" \
       bash "$CLEARRED" sole-copy-target --marker "$ATK_LINK" 2>&1)"; RC=$?
assert_exit "$RC" "1" "state redirect refused"

test_start "ATTACK B: state pointed at nothing must NOT downgrade to --john"
OUT="$(HOME="$RT_HOME" MAUDE_MARKER_STATE="$TEST_TMP/nope.json" \
       bash "$CLEARRED" sole-copy-target --john 2>&1)"; RC=$?
assert_exit "$RC" "1" "absence does not downgrade"

test_start "ATTACK C: CLAUDE_PLUGIN_ROOT pointed at a fake verifier is REFUSED"
FAKE="$TEST_TMP/fakeroot/maude_marker"; mkdir -p "$FAKE"
printf 'import sys\nsys.exit(0)\n' > "$FAKE/__main__.py"; : > "$FAKE/__init__.py"
OUT="$(HOME="$RT_HOME" CLAUDE_PLUGIN_ROOT="$TEST_TMP/fakeroot" \
       bash "$CLEARRED" sole-copy-target --marker "$ATK_LINK" 2>&1)"; RC=$?
assert_exit "$RC" "1" "fake verifier refused"

test_start "CONTROL: John's real link still WORKS (or this is just a wall)"
OUT="$(env -u MAUDE_MARKER_STATE -u MAUDE_MARKER_LEDGER -u CLAUDE_PLUGIN_ROOT \
       HOME="$RT_HOME" bash "$CLEARRED" sole-copy-target --marker "${RT_LINKS[4]}" 2>&1)"; RC=$?
assert_exit "$RC" "0" "real link accepted"

test_start "the red-self-clear backstop matches the key AFTER a flag value"
GATE_SH="$HOOKS_DIR/maude-gate.sh"
OUT="$(make_bash_tool_input "bash $CLEARRED --marker abc sole-copy-target" | bash "$GATE_SH" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "key after flag value still caught"

test_start "chain.init takes a lock (concurrent init cannot roll a head back)"
python3 - "$TEST_TMP" "$ROOT" <<'PYEOF'
import sys, os, threading, hashlib
sys.path.insert(0, sys.argv[2])
from maude_marker import chain
st = os.path.join(sys.argv[1], "lock-probe.json")
seed = b"s"; cur = hashlib.sha256(seed).hexdigest()
link = cur; head = hashlib.sha256(cur.encode()).hexdigest()
chain.init(st, "k", head, count=1)
ok = []
def spam(i):
    for _ in range(12):
        chain.init(st, "other%d" % i, head, count=1)
ts = [threading.Thread(target=spam, args=(i,)) for i in range(6)]
for t in ts: t.start()
for _ in range(12):
    ok.append(chain.verify_and_consume(st, "k", link)[0])
for t in ts: t.join()
sys.exit(0 if ok.count(True) <= 1 else 1)
PYEOF
assert_exit "$?" "0" "one link consumed at most once under concurrent init"

# ── THE SPLIT (2026-07-30) ──────────────────────────────────────────────────
# The deny-rule that closes the remaining forgeries has to be PATH-based. An
# argument-shaped rule inherits exactly the weakness the redteam exploited: it put
# the key after a flag value and walked past a grep expecting it after flags. There
# are always more spellings.
#
# But denying `maude-clear-gate.sh` wholesale would also block Claude clearing
# git-push, a YELLOW key he is meant to self-clear, so every push would need John's
# hand. He does not do git. A protection that makes him do a chore twenty times a day
# gets torn out, which is the same failure as a gate someone switches off.
#
# So the dangerous capability moves to its own path. Yellow keys stay in
# maude-clear-gate.sh, which refuses red outright; red lives in maude-clear-red.sh
# and nothing else does. Then the permission layer can name the file, and argument
# order stops mattering.

test_start "the red script exists"
assert_file_exists "$CLEARRED" "clear-red present"

test_start "clear-gate REFUSES a red key outright"
OUT="$(bash "$CLEAR" sole-copy-target --john 2>&1)"; RC=$?
assert_exit "$RC" "1" "yellow script refuses red"

test_start "its refusal points at the red script by name"
assert_contains "$OUT" "maude-clear-red.sh" "names the red script"

test_start "clear-gate refuses EVERY red key, not just the one"
FAILED_KEYS=""
for k in rm-rf-root rm-rf-glob sudo-rm-rf rm-rf-sole-copy sole-copy-target \
         public-publish force-push filter-repo filter-branch infra-destructive drop-table; do
  bash "$CLEAR" "$k" --john >/dev/null 2>&1 && FAILED_KEYS="$FAILED_KEYS $k"
done
assert_eq "$FAILED_KEYS" "" "no red key clears via the yellow script"

test_start "clear-gate still clears EVERY yellow key"
BAD=""
for k in git-push commit-amend no-verify no-gpg-sign reset-hard run-governor; do
  bash "$CLEAR" "$k" >/dev/null 2>&1 || BAD="$BAD $k"
done
assert_eq "$BAD" "" "all yellow keys still self-clearable"

test_start "the red script REFUSES a yellow key (one job each)"
OUT="$(bash "$CLEARRED" git-push --john 2>&1)"; RC=$?
assert_exit "$RC" "1" "red script refuses yellow"

test_start "clear-gate contains no red-token write path any more"
assert_eq "$(grep -c 'maude_redclear_file' "$CLEAR")" "0" "no redclear writes in the yellow script"

test_start "the gate backstop catches the RED script too"
GATE_SH2="$HOOKS_DIR/maude-gate.sh"
OUT="$(make_bash_tool_input "bash $CLEARRED sole-copy-target --marker abc" | bash "$GATE_SH2" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "clear-red invocation blocked for Claude"

print_summary
teardown_test_env
