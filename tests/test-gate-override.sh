#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: the override token, pattern order, the jq-absent contract, sole-copy rm, the arg walk, public-publish, the red-key backstop and its own token store.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

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

print_summary
teardown_test_env
exit $FAILED
