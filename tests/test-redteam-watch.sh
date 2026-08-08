#!/usr/bin/env bash
# Tests for hooks/scripts/maude-redteam-watch.sh — the adversarial-pass tripwire.
#
# WHY THIS FILE EXISTS
# --------------------
# John, 2026-07-30: "make note about this and what im expecting as red-teams/adversarials
# et all. there's no reason we can[']t do thes types of things ourselves, we were doing it
# before antrhopic pushed" · "we are always dogfooding".
#
# The standing expectation is that EVERY build gets an adversarial pass before it is called
# done, launched by Claude, using our own sub configs. Maude already HELD that preference —
# ~/.claude/maude/identity.md carries the tiering correction verbatim ("redteams use models
# for the tasks dont lock us down that small") and the uniform-bar rule next to it.
#
# It did nothing on 2026-07-30. Three builds shipped — a 9-site gate fix, the mission rail,
# the whole UNDO pillar — with ZERO adversarial passes, because identity.md is 86KB read at
# wake and NOTHING CONSULTS IT AT THE MOMENT A BUILD FINISHES. Knowledge in a file is a
# diary; a hook is a rail. Build the gate, not the wardrobe.
#
# Mirrors maude-verify-watch.sh exactly: stamp on the event, check at the commit, whisper
# only, never block.
#
# THE ASYMMETRY THAT MAKES IT SAFE
# A missed stamp costs one extra advisory whisper. A false stamp manufactures "you're
# covered" when nothing reviewed the work. So detection errs toward NOT stamping, and the
# check errs toward whispering.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

RT="$HOOKS_DIR/maude-redteam-watch.sh"
CARE="$(care_path)"

reset_all() { printf '{}\n' > "$CARE"; : > "$(trace_path)"; }
last_rt()   { read_care '.last_redteam_iso'; }

# Payloads copied from REAL Agent dispatches in this workspace's transcripts —
# input keys: description, model, prompt, run_in_background, subagent_type.
agent_done() {  # $1 = description, $2 = prompt
  jq -nc --arg d "$1" --arg p "$2" \
    '{tool_name:"Agent", hook_event_name:"PostToolUse",
      tool_input:{description:$d, prompt:$p, subagent_type:"general-purpose", model:"haiku"},
      tool_response:[{type:"text", text:"findings: 3"}]}'
}
bash_commit() { jq -nc '{tool_name:"Bash", hook_event_name:"PreToolUse",
                         tool_input:{command:"git commit -m wip"}}'; }
seed_edit() {   # $1 = path, $2 = ts
  jq -nc --arg t "$1" --arg ts "$2" '{ts:$ts, kind:"tool", tool:"Edit", target:$t}' >> "$(trace_path)"
}

# ── STAMP — only a genuinely adversarial dispatch counts ────────────────────

test_start "an adversarial review dispatch stamps last_redteam_iso"
reset_all
agent_done "Adversarial review of the federation rename" \
           "You are an adversarial code reviewer. A rename was just made." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "stamped"

test_start "a redteam-worded dispatch stamps"
reset_all
agent_done "Haiku redteam of the guard" "Break this. Find inputs the tests do not cover." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "redteam wording stamped"

test_start "a second-lens dispatch stamps"
reset_all
agent_done "Haiku cadence judge on my draft" "a second lens on a draft written by an AI assistant" | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "second lens stamped"

# The real negative, taken from a real transcript: an IMPLEMENTER dispatch.
test_start "a BUILD dispatch does NOT stamp (the implementer is not a lens)"
reset_all
agent_done "Build 7e first-light wiring TDD" \
           "You are a careful TDD implementer in the WICK monorepo. Implement Inc 7e." | bash "$RT" stamp
assert_eq "$(last_rt)" "null" "implementer did not stamp"

# The two guards MASK EACH OTHER unless the cases are separated. Mutation proved it:
# removing the builder guard changed nothing (the implementer text has no adversarial
# words), and removing the adversarial match changed nothing (the builder guard caught it).
# Each of these isolates exactly one guard.
test_start "a BUILDER dispatch that also says 'find the bugs' still does NOT stamp"
reset_all
agent_done "Build the parser" \
           "You are a careful TDD implementer. Implement it, then find the bugs in the spec." | bash "$RT" stamp
assert_eq "$(last_rt)" "null" "builder guard wins over adversarial wording"

test_start "a dispatch that is NEITHER builder nor adversarial does NOT stamp"
reset_all
agent_done "Summarize the changelog" "List the entries added since the last tag." | bash "$RT" stamp
assert_eq "$(last_rt)" "null" "a plain worker is not a lens"

test_start "a non-Agent tool does NOT stamp"
reset_all
bash_commit | bash "$RT" stamp
assert_eq "$(last_rt)" "null" "Bash did not stamp"

test_start "an INTERRUPTED adversarial dispatch does NOT stamp"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse",
         tool_input:{description:"Adversarial review", prompt:"redteam this"},
         tool_response:{interrupted:true}}' | bash "$RT" stamp
assert_eq "$(last_rt)" "null" "killed dispatch is not a pass"

test_start "stamp never blocks"
agent_done "Adversarial review" "redteam this" | bash "$RT" stamp >/dev/null 2>&1
assert_exit "$?" "0" "stamp exits 0"

# ── CHECK — whisper at a commit of CODE with no adversarial pass since ──────

test_start "commit of code with NO redteam ever whispers"
reset_all
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
ERR="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERR" "adversarial" "whispered about the missing pass"

test_start "…and the whisper names what to do, not just what is wrong"
assert_contains "$ERR" "redteam" "names the remedy"

test_start "commit of code AFTER a redteam is silent"
reset_all
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
# .last_redteam_iso is an OBJECT keyed by 8-char sid (the trace's own identity field) —
# five lanes share this care.json, and an unscoped stamp would let one lane's redteam
# silence another lane's whisper. Test payloads carry no session_id, so they key "default".
maude_set_rt() { jq --arg ts "$1" '.last_redteam_iso = {default: $ts}' "$CARE" > "$CARE.t" && mv "$CARE.t" "$CARE"; }
maude_set_rt "2026-07-30T06:00:00Z"
ERR2="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERR2" "" "silent when a pass came after the edits"

test_start "a redteam BEFORE the edits does not count"
reset_all
maude_set_rt "2026-07-30T04:00:00Z"
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
ERR3="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERR3" "adversarial" "stale pass still whispers"

test_start "a DOCS-only commit is silent (a gate that nags gets switched off)"
reset_all
seed_edit "$TEST_TMP/README.md" "2026-07-30T05:00:00Z"
seed_edit "$TEST_TMP/CHANGELOG.md" "2026-07-30T05:01:00Z"
ERR4="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERR4" "" "docs-only does not whisper"

test_start "a non-commit Bash command is silent"
reset_all
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
ERR5="$(jq -nc '{tool_name:"Bash",tool_input:{command:"ls -la"}}' | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERR5" "" "ls does not whisper"

test_start "check never blocks"
bash_commit | bash "$RT" check >/dev/null 2>&1
assert_exit "$?" "0" "check exits 0"

# ── THE WIRING — a rail nothing calls is not a rail ─────────────────────────
# This is the whole lesson of 2026-07-30: the mission rail was registered, matched, and
# dead. Drive the REGISTERED scripts, not this one directly.

test_start "the registered PostToolUse trace hook invokes the stamp"
reset_all
agent_done "Adversarial review of the undo pillar" "You are an adversarial reviewer. Break it." \
  | bash "$HOOKS_DIR/maude-trace.sh" tool >/dev/null 2>&1
assert_ne "$(last_rt)" "null" "stamped via the real trace hook"

test_start "the registered PreToolUse bash hook invokes the check"
reset_all
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
ERR6="$(bash_commit | bash "$HOOKS_DIR/maude-bash-watch.sh" 2>&1 >/dev/null)"
assert_contains "$ERR6" "adversarial" "whispered via the real bash hook"

# ── PER-SESSION ISOLATION ───────────────────────────────────────────────────
# The mission pin had exactly this bug the same night: care.json is one file for every
# session at a root. A sibling lane's redteam must not silence yours, and its edits must
# not be counted against you.
agent_done_sid() {  # $1 = session_id, $2 = description, $3 = prompt
  jq -nc --arg s "$1" --arg d "$2" --arg p "$3" \
    '{tool_name:"Agent", session_id:$s, hook_event_name:"PostToolUse",
      tool_input:{description:$d, prompt:$p}, tool_response:[{type:"text",text:"ok"}]}'
}
commit_sid() { jq -nc --arg s "$1" '{tool_name:"Bash", session_id:$s,
                                     tool_input:{command:"git commit -m wip"}}'; }
seed_edit_sid() { jq -nc --arg t "$1" --arg ts "$2" --arg sid "$3" \
  '{ts:$ts, kind:"tool", tool:"Edit", target:$t, sid:$sid}' >> "$(trace_path)"; }

test_start "a SIBLING session's redteam does not silence this session's whisper"
reset_all
agent_done_sid "aaaaaaaa-1111" "Adversarial review" "redteam it" | bash "$RT" stamp
seed_edit_sid "$TEST_TMP/src/mine.sh" "2026-07-30T09:00:00Z" "bbbbbbbb"
ERRX="$(commit_sid "bbbbbbbb-2222" | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERRX" "adversarial" "sibling pass did not cover me"

test_start "a sibling session's EDITS are not counted against this session"
reset_all
agent_done_sid "bbbbbbbb-2222" "Adversarial review" "redteam it" | bash "$RT" stamp
seed_edit_sid "$TEST_TMP/src/theirs.sh" "2026-07-30T09:00:00Z" "aaaaaaaa"
ERRY="$(commit_sid "bbbbbbbb-2222" | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERRY" "" "another lane's edits are not my debt"

# Isolates the STAMP KEY specifically. The sibling test above passes even if the stamp
# writes to a fixed key, because the reader still looks under a different one. This case
# reads under "default" (no session_id), so a stamp that ignored the sid WOULD silence it.
test_start "a sibling's pass does not silence an unkeyed reader either"
reset_all
agent_done_sid "aaaaaaaa-1111" "Adversarial review" "redteam it" | bash "$RT" stamp
# The edit ts must be EARLIER than the stamp's wall-clock, or the case cannot tell the two
# behaviours apart: a late edit reads as "after the pass" whether the stamp landed under
# this key or another. Measured — the first version of this row used 09:00Z and survived
# the mutation it was written to catch.
seed_edit "$TEST_TMP/src/mine.sh" "2026-07-30T00:00:01Z"
ERRZ="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERRZ" "adversarial" "a real sid's stamp must not land under default"

print_summary
teardown_test_env
exit $FAILED
