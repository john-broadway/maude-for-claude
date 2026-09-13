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
# A SYNCHRONOUS Agent completion, captured 2026-08-13T02:00:53Z from this box's own
# transcript (toolUseResult == the hook's tool_response): it carries agentId and agentType
# and content and status "completed", and NO isAsync. The launch helper was re-pointed at a
# captured envelope on 2026-09-06 and this one was left invented (an array of text blocks,
# which is the assistant message's tool_result.content, not the hook's input) — so the one
# test for the completion case could not see the 25th lens's BLOCKING-1, where a real
# completed pass was filed as a launch still in flight.
agent_done() {  # $1 = description, $2 = prompt
  jq -nc --arg d "$1" --arg p "$2" \
    '{tool_name:"Agent", hook_event_name:"PostToolUse",
      tool_input:{description:$d, prompt:$p, subagent_type:"general-purpose", model:"opus"},
      tool_response:{status:"completed", agentId:"ac304b971b23454ba", agentType:"general-purpose",
                     content:[{type:"text", text:"findings: 3"}], prompt:$p,
                     resolvedModel:"claude-opus-5[1m]", totalDurationMs:799981,
                     totalTokens:147977, totalToolUseCount:42}}'
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
# Measured 2026-08-17 over the transcripts then held (a rolling window; not reproducible at a
# later count) against 8 real lens dispatches: only 1 stamped. The other 7 asked
# the reviewer to "build the table" of findings, and `build the` in BUILDER_RE read that
# as an implementer. The motivating negative for that phrase ("Build 7e first-light
# wiring") does not even contain it — "implementer" is what catches that one. So the
# phrase was costing real stamps and earning nothing.
test_start "an adversarial brief told to BUILD THE TABLE of findings still stamps"
reset_all
agent_done "Lens 2: guard and visibility contract" \
           "You are an independent adversarial reviewer. Build the complete table by grepping for every write, then verify each by execution. Try to break the claim." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "a lens asked to build a findings table must still stamp"

test_start "an adversarial brief told to BUILD THE LIST still stamps"
reset_all
agent_done "Round-4 fix review" \
           "Attack the fixes. Build the coverage list from your own grep and prove each row by running it." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "build the list must not read as an implementer"

test_start "a BUILD dispatch does NOT stamp (the implementer is not a lens)"
reset_all
agent_done "Build 7e first-light wiring TDD" \
           "You are a careful TDD implementer in the estate monorepo. Implement Inc 7e." | bash "$RT" stamp
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

# ── STAMP — the stamp must NAME what it reviewed ────────────────────────────
# A timestamp alone proves only that a dispatch FINISHED after a commit, never that it
# SAW that commit. Measured 2026-09-04: the v0.31.0 release commit (16:09:57Z) was covered
# by a stamp written 48 seconds later by a dispatch that began before the commit existed,
# and the ship gate read that as proven. So the stamp records the refs the brief NAMES and
# ship.sh checks them against the tip. A brief that names none still stamps — the commit
# whisper below wants the timestamp — but it earns no credit at the gate.

test_start "a dispatch that names a sha records it as the reviewed ref"
reset_all
agent_done "Adversarial lens on the release diff" \
           "You are a hostile second lens. Subject: git show 7e36d82 in the maude repo." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "7e36d82" "named ref recorded"

# `.ts` on the OLD string shape makes jq error, read_care swallows it, and an
# assert_ne against "null" then passes on the empty string — a green that cannot go red.
# Assert the SHAPE instead, which only a real object stamp can satisfy.
test_start "the ref-bearing stamp still carries its timestamp"
assert_eq "$(read_care '.last_redteam_iso.default.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" \
           "true" "ts present, ISO, alongside refs"

test_start "a dispatch that names NO sha stamps a timestamp with no refs"
reset_all
agent_done "Adversarial review of the wording" "Attack the prose. Nothing here to point at." | bash "$RT" stamp
assert_ne "$(read_care '.last_redteam_iso.default.ts')" "null" "refless dispatch still stamps a ts"
assert_eq "$(read_care '.last_redteam_iso.default.refs | length')" "0" "and claims no refs"

test_start "a range names BOTH ends and both are recorded"
reset_all
agent_done "Adversarial lens" "Review the range 1c893d3..7e36d82, hardest first." | bash "$RT" stamp
REFS="$(read_care '.last_redteam_iso.default.refs | join(",")')"
assert_contains "$REFS" "1c893d3" "range start recorded"
assert_contains "$REFS" "7e36d82" "range end recorded"

# Found 2026-09-04 by the lens on this very commit: the scraper piped `sort -u | head -20`,
# which SORTS BEFORE TRUNCATING. A brief carrying twenty-odd hex-looking words could sort
# the real sha out of the list, and the gate would then refuse a review that genuinely
# happened. Order of appearance is the honest order: a brief names its subject early.
test_start "a brief full of hex decoys still records the real ref"
reset_all
DECOYS=""; i=1
while [ "$i" -le 25 ]; do DECOYS="$DECOYS 0abcde$(printf '%02d' "$i")"; i=$((i+1)); done
agent_done "Adversarial lens" "Attack the tip 3562df8. Context:$DECOYS" | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "3562df8" \
  "the real ref survives a crowd of decoys"

test_start "and the recorded refs stay capped"
CAPN="$(read_care '.last_redteam_iso.default.refs | length')"
[ "${CAPN:-0}" -le 64 ] && assert_eq "ok" "ok" "capped at 64" \
                        || assert_eq "$CAPN" "<=64" "cap exceeded"

# The control for the scraper: too-short hex is a word, not a sha. Six characters is the
# longest accidental hex run common in prose, so the floor sits at seven — git's own
# shortest abbreviation.
test_start "a short hex word is NOT mistaken for a ref"
reset_all
agent_done "Adversarial review" "Attack it. All abc123 of it." | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.default.refs | length')" "0" "six hex chars is too short to be a sha"

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

test_start "the commit whisper reads the timestamp out of a ref-bearing stamp"
reset_all
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
jq '.last_redteam_iso = {default: {ts:"2026-07-30T06:00:00Z", refs:["7e36d82"]}}' "$CARE" > "$CARE.t" \
  && mv "$CARE.t" "$CARE"
ERR2B="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERR2B" "" "the object shape must not break the whisper"

# The control for the line above. Rendered as JSON text an object sorts ABOVE every
# timestamp, so a broken reader is silent for EVERY edit and the silence proves nothing.
# Here the pass predates the edit and the whisper MUST fire.
test_start "a ref-bearing stamp OLDER than the edits still whispers"
reset_all
jq '.last_redteam_iso = {default: {ts:"2026-07-30T04:00:00Z", refs:["7e36d82"]}}' "$CARE" > "$CARE.t" \
  && mv "$CARE.t" "$CARE"
seed_edit "$TEST_TMP/src/thing.sh" "2026-07-30T05:00:00Z"
ERR2C="$(bash_commit | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERR2C" "adversarial" "a stale ref-bearing pass must still whisper"

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
agent_done_sid() {  # $1 = session_id, $2 = description, $3 = prompt — the CAPTURED completion envelope (see agent_done)
  jq -nc --arg s "$1" --arg d "$2" --arg p "$3" \
    '{tool_name:"Agent", session_id:$s, hook_event_name:"PostToolUse",
      tool_input:{description:$d, prompt:$p},
      tool_response:{status:"completed", agentId:"ac304b971b23454ba", agentType:"general-purpose",
                     content:[{type:"text", text:"ok"}], prompt:$p, totalDurationMs:1234}}'
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


# ── STAMP — a background launch is a LAUNCH, not a pass ───────────────────────
# The Agent tool returns at launch for a background dispatch, and PostToolUse fires then
# with the launch as the whole response. That response is an OBJECT, captured 2026-09-06
# 19:14Z from this box's own transcript (the harness's toolUseResult is the hook's
# tool_response): {isAsync:true, status:"async_launched", agentId:"…", description,
# resolvedModel, prompt}. It is NOT the "Async agent launched … agentId: …" text the
# model reads; the first live launch on this branch (the 24th lens) was stamped as a pass
# because the hook read text shapes only. A stamp
# written at that moment is a LAUNCH stamp: on 2026-09-06 the 23rd lens died with its
# session three minutes after dispatch and care.json still named the tip as reviewed.
# So a background launch records a PENDING entry keyed by the agent id, and the
# subagent-stop hook PROMOTES it to a stamp when that agent actually finishes (the
# harness's SubagentStop stdin carries agent_id). A dead lens never promotes; a commit
# check against a pending entry whispers as if there had been no pass, and says why.
SUB="$HOOKS_DIR/maude-subagent-stop.sh"
agent_launched() {  # $1 = description, $2 = prompt, $3 = agent id (the CAPTURED launch envelope, see above)
  jq -nc --arg d "$1" --arg p "$2" --arg id "$3" \
    '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
      tool_input:{description:$d, prompt:$p, subagent_type:"general-purpose", model:"opus"},
      tool_response:{isAsync:true, status:"async_launched", agentId:$id, description:$d,
                     resolvedModel:"claude-opus-5[1m]", prompt:$p,
                     outputFile:("/tmp/" + $id + ".output"), canReadOutputFile:true}}'
}
subagent_stop() {  # $1 = agent id, $2 = agent type (SubagentStop stdin per the hooks reference)
  jq -nc --arg id "$1" --arg t "$2" \
    '{hook_event_name:"SubagentStop", session_id:"sess1111-aaaa-bbbb", agent_id:$id, agent_type:$t, stop_reason:"end_turn"}'
}
commit_s()    { jq -nc '{tool_name:"Bash", hook_event_name:"PreToolUse", session_id:"sess1111-aaaa-bbbb", tool_input:{command:"git commit -m wip"}}'; }
seed_edit_s() { jq -nc --arg t "$1" --arg ts "$2" '{ts:$ts, kind:"tool", tool:"Edit", target:$t, sid:"sess1111"}' >> "$(trace_path)"; }
AID="a7f93cda58bbfd3cf"

test_start "a background adversarial launch does NOT stamp last_redteam_iso"
reset_all
agent_launched "Adversarial lens on the range" \
  "You are a hostile second lens. Subject tip 7e36d82, range 1c893d3..7e36d82." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no stamp at launch"

test_start "…it records a PENDING entry keyed by the agent id, carrying the refs and the session"
assert_contains "$(read_care ".redteam_pending[\"$AID\"].refs | join(\",\")")" "7e36d82" "pending carries the named ref"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending carries the launching session"

test_start "a commit while the lens is only pending whispers NO pass, and says a lens is pending"
seed_edit_s "$TEST_TMP/hooks/scripts/x.sh" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ERR="$(commit_s | bash "$RT" check 2>&1 >/dev/null)"
assert_contains "$ERR" "NO adversarial pass" "pending is not a pass"
assert_contains "$ERR" "pending" "and the whisper says a lens is pending"

test_start "SubagentStop for that agent PROMOTES the pending entry to a stamp"
sleep 1
subagent_stop "$AID" "general-purpose" | bash "$SUB"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "7e36d82" "stamp carries the refs"
assert_eq "$(read_care '.last_redteam_iso.sess1111.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")')" "true" "stamp has an ISO ts"
assert_eq "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "pending consumed"

test_start "…and the commit check now sees the pass (the edit is older than the stamp)"
ERR="$(commit_s | bash "$RT" check 2>&1 >/dev/null)"
assert_eq "$ERR" "" "silent: covered"

test_start "SubagentStop for an UNKNOWN agent id promotes nothing"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
subagent_stop "deadbeefdeadbeef0" "general-purpose" | bash "$SUB"
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no stamp from a stranger's stop"
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "pending still waits"

test_start "a background BUILDER launch records no pending entry"
reset_all
agent_launched "Build the feature" "You are a careful TDD implementer. Implement it." "b1b1b1b1b1b1b1b1b" | bash "$RT" stamp
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "builder is not pending"

test_start "a background launch whose response carries NO agent id stamps nothing (it can never be promoted)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
         tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
         tool_response:[{type:"text", text:"Async agent launched successfully."}]}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no launch stamp"
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "no orphan pending"

test_start "the launch TEXT shape (what the model reads) still goes pending: a fallback, not the envelope"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
         tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
         tool_response:[{type:"text", text:("Async agent launched successfully.\nagentId: " + $id + " (internal ID)")}]}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no launch stamp from the text shape"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending from the text shape"

# The file's own rule: a MISSED stamp costs one whisper, a FALSE stamp manufactures "you're
# covered". An unrecognised launch shape must lean toward pending (the 24th lens,
# IMPORTANT-1: 6d59d1f stamped a full pass on any object it did not recognise).
test_start "an object carrying an agentId with neither isAsync nor status is a LAUNCH, not a pass (IMPORTANT-1)"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
         tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
         tool_response:{agentId:$id, description:"Adversarial lens"}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass from an unrecognised launch shape"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending under its id"

test_start "isAsync as the STRING \"true\" beside an agentId is a launch too"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
         tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
         tool_response:{isAsync:"true", agentId:$id}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending"

test_start "an agentId that is not a plain token (an object) records nothing: it could never be promoted (MINOR-3)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
         tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
         tool_response:{isAsync:true, status:"async_launched", agentId:{id:"x"}}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass"
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "no pending under a malformed key"

test_start "two lenses of one session both promoted: the stamp carries BOTH subjects (MINOR-2)"
reset_all
agent_launched "Adversarial lens" "Attack aaaaaaa1." "a1a1a1a1a1a1a1a1a" | bash "$RT" stamp
agent_launched "Adversarial lens" "Attack bbbbbbb2." "b2b2b2b2b2b2b2b2b" | bash "$RT" stamp
subagent_stop "a1a1a1a1a1a1a1a1a" "general-purpose" | bash "$SUB"
subagent_stop "b2b2b2b2b2b2b2b2b" "general-purpose" | bash "$SUB"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "aaaaaaa1" "the first lens's subject is kept"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "bbbbbbb2" "and the second's is added"

# An EXPLICIT launch marker outranks completion evidence: `agentType` is a property of the
# dispatch (the harness knows it at launch, and the launch envelope already carries
# description/resolvedModel/prompt), so the day it appears on a launch, ordering these the
# other way stamps every background lens as a finished pass at the moment it is dispatched —
# the 2026-09-06 failure this whole file exists to prevent (the 26th lens, IMPORTANT-1).
test_start "a launch envelope carrying agentType is STILL a launch, not a pass (26th lens, IMPORTANT-1)"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
  tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
  tool_response:{isAsync:true, status:"async_launched", agentId:$id, agentType:"general-purpose",
                 description:"Adversarial lens", prompt:"Attack 7e36d82."}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass while it says it is a launch"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending under its id"

test_start "…the same for a launch that carries content, and one that carries totalDurationMs"
for _extra in 'content:"a body"' 'totalDurationMs:0'; do
  reset_all
  jq -nc --arg id "$AID" "{tool_name:\"Agent\", hook_event_name:\"PostToolUse\", session_id:\"sess1111-aaaa-bbbb\",
    tool_input:{description:\"Adversarial lens\", prompt:\"Attack 7e36d82.\"},
    tool_response:{isAsync:true, status:\"async_launched\", agentId:\$id, $_extra}}" | bash "$RT" stamp
  assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass ($_extra)"
done

test_start "a SYNCHRONOUS adversarial completion still stamps at once (the response is the result)"
reset_all
agent_done "Adversarial review" "Attack 7e36d82." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "sync completion stamps"
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "and leaves NOTHING pending: it is finished"

test_start "…and its refs are the subject it was given, not an empty stamp"
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "7e36d82" "the sync stamp carries the subject"

test_start "a sync completion whose stop arrives BEFORE the tool returns leaves nothing pending (the real order for a synchronous call)"
reset_all
subagent_stop "ac304b971b23454ba" "general-purpose" | bash "$SUB"
agent_done "Adversarial review" "Attack 7e36d82." | bash "$RT" stamp
assert_ne "$(last_rt)" "null" "stamped"
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "nothing stuck pending forever"

# The stamp ASSIGNED refs where promote UNIONS them, so a later refless lens in the same
# session erased the subject a real promoted pass had recorded and ship.sh then refused a
# tip that genuinely was reviewed (the 26th lens, IMPORTANT-6).
test_start "a refless completion does not erase the subject an earlier pass recorded (26th lens, IMPORTANT-6)"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
subagent_stop "$AID" "general-purpose" | bash "$SUB"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "7e36d82" "the promoted subject is recorded"
agent_done "Adversarial review of some prose" "You are a hostile second lens. Read this paragraph for claims." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "7e36d82" "and a refless pass after it does NOT erase it"

# A lens that dies before its stop never promotes, so nothing deletes its pending entry:
# the wake names it forever and care.json grows on the path every hook reads (MINOR-3).
test_start "pending entries are pruned: an old one is dropped when a new launch is recorded (26th lens, MINOR-3)"
reset_all
printf '{"redteam_pending":{"deadbeef000000001":{"ts":"2026-08-01T00:00:00Z","refs":["aaaaaaa1"],"sid":"old1"}}}\n' > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.redteam_pending["deadbeef000000001"] // "gone"')" "gone" "the month-old entry is gone"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "and the new one is recorded"

test_start "…while a pending entry from today is kept"
reset_all
printf '{"redteam_pending":{"deadbeef000000002":{"ts":"%s","refs":["aaaaaaa1"],"sid":"old2"}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_ne "$(read_care '.redteam_pending["deadbeef000000002"] // "gone"')" "gone" "today's entry stays"

# A lens that ERRORED reviewed nothing. "Completion evidence" was read without ever asking
# whether the completion SUCCEEDED, so a failed, cancelled, timed-out or errored dispatch
# stamped a pass on the tip its brief named — the false all-clear this file exists to refuse
# (the 27th lens, IMPORTANT-1).
for _st in failed cancelled error timeout; do
  test_start "a completion whose status is \"$_st\" stamps NOTHING"
  reset_all
  jq -nc --arg s "$_st" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
    tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
    tool_response:{status:$s, agentId:"ac304b971b23454ba", agentType:"general-purpose",
                   content:[{type:"text", text:"Error: the agent exceeded its budget"}],
                   totalDurationMs:12}}' | bash "$RT" stamp
  assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass from a failed lens"
  assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "and nothing left pending: it is finished"
done

test_start "…and an is_error completion stamps nothing either"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
  tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
  tool_response:{status:"completed", is_error:true, agentId:"ac304b971b23454ba",
                 content:[{type:"text", text:"boom"}]}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass"

# `unique` SORTS, so `unique | .[-128:]` discards the lexicographically smallest — which can be
# the tip the session actually reviewed, and ship.sh then refuses the work it reviewed (the
# 27th lens, IMPORTANT-2). A set truncation has to keep the members you can still name.
test_start "past the ref cap the EARLIEST-recorded subject survives, not the one that sorts highest (27th lens, IMPORTANT-2)"
reset_all
printf '{"last_redteam_iso":{"sess1111":{"ts":"2026-09-06T01:00:00Z","refs":["0000001"]}}}\n' > "$(care_path)"
for _i in $(seq 1 40); do
  agent_done "Adversarial review" "You are a hostile second lens. Subject: fff000$_i fff100$_i fff200$_i fff300$_i." | bash "$RT" stamp
done
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "0000001" "the first subject recorded is still there"

test_start "…and promote and the stamp cap the same way (27th lens, MINOR-10)"
assert_eq "$(read_care '.last_redteam_iso.sess1111.refs | length <= 128')" "true" "the stamp is capped"

# The 50-cap evicts the OLDEST pending entry, which is the still-RUNNING lens; its promote then
# writes nothing and a real pass is lost. It must not be lost SILENTLY (27th lens, IMPORTANT-6).
# A fixture that must be YOUNG for the age prune (a week) carries timestamps RELATIVE to now:
# this one was written with a fixed date (2026-09-06) and went red on 2026-09-13 at 01:02Z
# when twelve of its sixty entries aged out, the cap never filled, and the eviction pin
# failed on a commit that changed one word of the CHANGELOG (found by the ship rail's
# build and by CI #283 the same minute). The three fixtures below share the class.
test_start "an eviction from the pending map is announced in the trace (27th lens, IMPORTANT-6)"
reset_all
python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc); ts=lambda h:(now-datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
p={('e%016x'%i):{'ts':ts(24+i%10),'refs':['aaa'],'sid':'s'} for i in range(60)}
sys.stdout.write(json.dumps({'redteam_pending':p}))
" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_contains "$(cat "$(trace_path)" 2>/dev/null)" "evicted" "the trace says entries were evicted"

# With no usable cutoff the prune keeps everything INCLUDING non-objects, and the very next
# sort_by then raises: the launch is not recorded at all and the hook blames a writable file
# (the 27th lens, IMPORTANT-7).
test_start "a non-object pending entry does not stop a launch being recorded when the cutoff cannot be made (27th lens, IMPORTANT-7)"
reset_all
python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc); ts=lambda h:(now-datetime.timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
p={('e%016x'%i):{'ts':ts(24+i%10),'refs':['aaa'],'sid':'s'} for i in range(55)}
p['junk']=42
sys.stdout.write(json.dumps({'redteam_pending':p}))
" > "$(care_path)"
NODATE="$(mktemp -d)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in -d|-r) exit 1;; esac; done\nexec %q "$@"\n' "$(command -v date)" > "$NODATE/date"; chmod +x "$NODATE/date"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | PATH="$NODATE:$PATH" bash "$RT" stamp
rm -rf "$NODATE"
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "the new launch IS recorded"

test_start "a pending entry whose ts is not a string is kept, not silently deleted (27th lens, MINOR-9a)"
reset_all
printf '{"redteam_pending":{"numts0000000000":{"ts":1234,"refs":["aaaaaaa1"],"sid":"s1"}}}\n' > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_ne "$(read_care '.redteam_pending["numts0000000000"] // "gone"')" "gone" "an unjudgeable age is kept, not pruned"

# The 50-session cap sorts on `.value.ts` over values it never guards, and a pre-2026-09-04
# stamp is a bare ISO STRING (ship.sh reads that shape in its own reader). On this box's live
# care.json — 94 sessions, 75 of them legacy strings — the whole sync stamp path raised and the
# trace blamed a writable file (the 28th lens, IMPORTANT-1).
test_start "a map holding LEGACY bare-string stamps past the session cap still records a stamp (28th lens, IMPORTANT-1)"
reset_all
python3 -c "
import json, sys
m = {('legacy%03d' % i): '2026-08-%02dT00:00:00Z' % (i % 28 + 1) for i in range(60)}
m['objectone'] = {'ts': '2026-09-01T00:00:00Z', 'refs': ['aaaaaaa1']}
sys.stdout.write(json.dumps({'last_redteam_iso': m}))
" > "$(care_path)"
agent_done "Adversarial review" "You are a hostile second lens. Subject: 7e36d82." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "7e36d82" "the stamp landed beside the legacy shapes"
assert_not_contains "$(cat "$(trace_path)" 2>/dev/null)" "care.json unwritable" "and nothing blamed a writable file"

# The status belt lived only in the stamp arm, so the ASYNC path — 366 of 404 dispatches on this
# box (measured 09-08 over the transcripts then held; the window has rolled since) — on this
# box — promoted a full pass for a lens that errored, failed, was cancelled or was interrupted
# (the 28th lens, IMPORTANT-2).
for _bad in '"status":"error","is_error":true' '"status":"failed"' '"status":"cancelled","interrupted":true'; do
  test_start "a stop reporting $_bad does NOT promote a pass"
  reset_all
  agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
  jq -nc --arg id "$AID" "{hook_event_name:\"SubagentStop\", session_id:\"sess1111-aaaa-bbbb\", agent_id:\$id, agent_type:\"general-purpose\", $_bad}" | bash "$SUB"
  assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no pass from a dispatch that failed"
  assert_eq "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "and the pending entry is cleared: it finished"
done

test_start "…while an ordinary stop still promotes"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
subagent_stop "$AID" "general-purpose" | bash "$SUB"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "7e36d82" "the good stop promotes"

# `.[0:128]` on (existing + new) locks a full session out forever: the ref that decides the ship
# gate is always the most recently added one (the 28th lens, IMPORTANT-3).
test_start "a session already at the ref cap can still name a NEW subject (28th lens, IMPORTANT-3)"
reset_all
python3 -c "
import json, sys
sys.stdout.write(json.dumps({'last_redteam_iso': {'default': {'ts': '2026-09-01T00:00:00Z', 'refs': ['%040x' % i for i in range(128)]}}}))
" > "$(care_path)"
agent_done "Adversarial review" "You are a hostile second lens. Subject: abcdef1." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "abcdef1" "the newly reviewed subject is in the stamp"
assert_eq "$(read_care '.last_redteam_iso.default.refs | length <= 128')" "true" "and the list is still capped"

test_start "…and a promote into a full stamp keeps the subject it carried"
reset_all
python3 -c "
import json, sys
sys.stdout.write(json.dumps({'last_redteam_iso': {'sess1111': {'ts': '2026-09-01T00:00:00Z', 'refs': ['%040x' % i for i in range(128)]}}}))
" > "$(care_path)"
agent_launched "Adversarial lens" "Attack beeff00." "$AID" | bash "$RT" stamp
subagent_stop "$AID" "general-purpose" | bash "$SUB"
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "beeff00" "promote's subject survives a full stamp"

# An UNRECOGNISED status must not make a dispatch invisible: no stamp, no pending, no wake line
# is the 23rd-lens failure restored (the 28th lens, IMPORTANT-7).
test_start "a launch whose status this build does not know is STILL recorded pending (28th lens, IMPORTANT-7)"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
  tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
  tool_response:{status:"dispatched", agentId:$id, description:"Adversarial lens", prompt:"Attack 7e36d82.",
                 outputFile:"/tmp/x.output", canReadOutputFile:true}}' | bash "$RT" stamp
assert_eq "$(read_care ".redteam_pending[\"$AID\"].sid")" "sess1111" "pending under its id"
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "and no pass"

test_start "…and a KNOWN failure status still records nothing at all"
reset_all
jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
  tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
  tool_response:{status:"error", agentId:$id, content:"the agent exceeded its budget"}}' | bash "$RT" stamp
assert_eq "$(read_care '.redteam_pending // "absent"')" "absent" "nothing pending for a launch that errored"

test_start "is_error of any truthy shape blocks, not only true (28th lens, MINOR-7)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
  tool_input:{description:"Adversarial review", prompt:"Attack 7e36d82."},
  tool_response:{status:"completed", is_error:1, agentId:"ac304b971b23454ba", content:[{type:"text",text:"x"}]}}' | bash "$RT" stamp
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "is_error: 1 blocks"

test_start "an EMPTY-OBJECT pending entry is pruned, not kept forever (28th lens, MINOR-1)"
reset_all
printf '{"redteam_pending":{"empty0000000000":{},"good00000000001":{"ts":"%s","refs":["aaaaaaa1"],"sid":"s1"}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.redteam_pending["empty0000000000"] // "gone"')" "gone" "an entry nothing can promote is dropped"
assert_ne "$(read_care '.redteam_pending["good00000000001"] // "gone"')" "gone" "a promotable one stays"

test_start "the eviction notice fires only when the CAP evicted, not when the age prune ran (28th lens, IMPORTANT-6)"
reset_all
python3 -c "
import json, sys
p = {('old%013d' % i): {'ts': '2026-08-01T00:00:00Z', 'refs': ['aaa'], 'sid': 's'} for i in range(10)}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_not_contains "$(cat "$(trace_path)" 2>/dev/null)" "pending map full" "an age prune is not an eviction"

test_start "…and a real cap eviction says how many were lost"
reset_all
python3 -c "
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc); ts = (now - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
p = {('f%015d' % i): {'ts': ts, 'refs': ['aaa'], 'sid': 's'} for i in range(60)}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_contains "$(cat "$(trace_path)" 2>/dev/null)" "pending map full" "the real eviction is named"

test_start "promote caps sessions the same way the stamp does (28th lens, MINOR-2)"
reset_all
python3 -c "
import json, sys
m = {('s%015d' % i): {'ts': '2026-09-01T00:00:00Z', 'refs': ['aaa']} for i in range(60)}
sys.stdout.write(json.dumps({'last_redteam_iso': m, 'redteam_pending': {}}))
" > "$(care_path)"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
subagent_stop "$AID" "general-purpose" | bash "$SUB"
assert_eq "$(read_care '.last_redteam_iso | length <= 50')" "true" "promote caps too"

test_start "stamp and promote never block"
reset_all
RC1="$(agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp >/dev/null 2>&1; echo $?)"
RC2="$(subagent_stop "$AID" "general-purpose" | bash "$SUB" >/dev/null 2>&1; echo $?)"
assert_eq "$RC1$RC2" "00" "both exit 0"

# ── a lens KILLED with TaskStop leaves no immortal pending entry ───────────────────
# Live on this box: on 2026-09-06 session 41158c31 launched an adversarial lens
# (ad21d0f7) at 19:35:14Z and killed it 5m27s later with TaskStop by id — the correct
# move under stop-the-waiter-you-outran. A killed agent never emits a SubagentStop for
# its OWN id, so not one branch here fired: the entry sat pending until the 7-day age
# prune, and every wake in between named a lens that was not running. The promote path
# already clears on cancelled/aborted/interrupted, but only when a stop ARRIVES; a kill
# is the one ending that sends nothing. Envelope captured verbatim from that session's
# transcript (tool_response == the harness's toolUseResult).
task_stopped() {  # $1 = task id
  jq -nc --arg id "$1" \
    '{tool_name:"TaskStop", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
      tool_input:{task_id:$id},
      tool_response:{message:("Successfully stopped task: " + $id + " (Lens the FOR-JOHN walk note)"),
                     task_id:$id, task_type:"local_agent", command:"Lens the FOR-JOHN walk note"}}'
}

test_start "TaskStop on a pending lens clears its entry"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "pending to begin with"
task_stopped "$AID" | bash "$RT" stamp
assert_eq "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the killed lens is no longer pending"

test_start "…and it stamps NOTHING: a killed lens reviewed nothing"
assert_eq "$(read_care '.last_redteam_iso.sess1111 // "absent"')" "absent" "no false pass from a kill"

test_start "a TaskStop the classifier DENIED clears nothing: the lens is still running"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
jq -nc --arg id "$AID" '{tool_name:"TaskStop", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
   tool_input:{task_id:$id},
   tool_response:"Error: Permission for this action was denied by the Claude Code auto mode classifier."}' \
  | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "a refused stop killed nothing, so the entry stays"

test_start "TaskStop on an id nothing is pending on leaves the others alone"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
task_stopped "deadbeefdeadbeef0" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "a stranger's stop is a no-op"

test_start "TaskStop never blocks"
RC3="$(task_stopped "$AID" | bash "$RT" stamp >/dev/null 2>&1; echo $?)"
assert_eq "$RC3" "0" "exit 0"

# ── the trace must not claim a clear the store never got (29th lens, IMPORTANT-1) ──
# maude_care_set returns 0 only if the bytes landed, precisely so a caller can avoid
# claiming a write that dropped (_maude-common.sh). The first cut of the TaskStop branch
# discarded that return and logged "pending entry cleared" unconditionally, while the
# sibling one file away (maude-verify-watch.sh) had honoured the contract all along. A
# lying diagnostic is the cheap half of this failure — the entry survives, so the wake
# still names the lens — but a reader who greps the trace for what happened is told the
# opposite of the truth, and that is the one thing our code must never do.
test_start "when the store cannot be written, the trace says so instead of claiming a clear"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
# A DIRECTORY where flock wants a file: the write cannot land. `rm` first — the launch
# above already created the lock as a regular FILE, so a bare `mkdir -p` silently fails
# and the store stays writable, which is a fixture that proves nothing (caught here by
# the entry vanishing when the test said it should have survived). chmod is not the lever
# on this box: the suite runs as root, and root walks through the permission bits.
rm -rf "$CARE.lock"; mkdir "$CARE.lock"; chmod a-w "$(dirname "$CARE")"   # non-root (CI, macOS): the temp beside care.json cannot be made
task_stopped "$AID" | bash "$RT" stamp
chmod u+w "$(dirname "$CARE")"; rmdir "$CARE.lock" 2>/dev/null   # back to a plain path so the next test can write
TR="$(cat "$(trace_path)")"
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the entry really did survive"
assert_not_contains "$TR" "pending entry cleared" "so the trace must NOT claim it was cleared"
assert_contains "$TR" "could not clear" "it says the store was unwritable"

# The id guard is a CHARACTER-CLASS test, and a bracket range is collation, not bytes:
# under a UTF-8 locale `[!A-Za-z0-9_-]` ADMITS the fullwidth ａ (U+FF41), the ligature ﬀ
# (U+FB00) and the Arabic-Indic ١ (U+0661), all of which C rejects. So the guard's meaning
# moved with the box's locale (29th lens, MINOR-3).
#
# TWO things this file got wrong in the round that "fixed" it, both found by the 30th lens:
#
#   1. There are TWO identifier guards in maude-redteam-watch.sh — the one that decides
#      which agent id becomes a pending KEY, and the one that decides which id may CLEAR
#      it. Only the clear side was converted, so the two disagreed under UTF-8: the writer
#      recorded an id the killer then refused, and the entry could never be cleared. That
#      is the exact failure the kill branch exists to end, reintroduced by fixing the shape
#      instead of the class. Both sides now call one helper and cannot drift again.
#
#   2. The regression pin only went red under en_US.UTF-8, and NOTHING in this repo pins a
#      locale — not tests/run.sh, not tests/lib.sh, not either CI workflow. A check whose
#      ability to see its own failure depends on the runner's ambient collation is not a
#      check. So both sides are asserted under every locale this box actually has, and a
#      box with no UTF-8 locale installed says so out loud instead of passing quietly.
maude_test_locales() {   # C, plus every UTF-8 locale actually installed here
  local l out="C"
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    locale -a 2>/dev/null | grep -qxF "$l" && out="$out $l"
  done
  printf '%s' "$out"
}
LOCALES="$(maude_test_locales)"
# Say out loud, on EVERY run, which locales the collation pins ran under and which of them
# actually ADMIT the fullwidth letter in a bracket range — because only a locale that admits
# it can see the write-side guard fail. The 32nd lens measured that a runner with C plus
# C.utf8 alone runs this file GREEN with the write-side bug put back, at exactly the count
# CI printed on the healthy tree; nothing in that log said which locales it had. tests/run.sh
# passes NOTE lines through on a PASS, so this line reaches the CI log.
maude_admits_fullwidth() {   # $1 = locale; prints admit|reject for the `case` bracket form
  LC_ALL="$1" bash -c 'case "$(printf "a\xef\xbd\x811")" in *[!A-Za-z0-9_-]*) printf reject;; *) printf admit;; esac' 2>/dev/null
}
_ADMITS=""; _REJECTS=""
for L in $LOCALES; do
  case "$(maude_admits_fullwidth "$L")" in admit) _ADMITS="$_ADMITS $L" ;; *) _REJECTS="$_REJECTS $L" ;; esac
done
_NOTE_LOCALES="$(printf '  NOTE  collation pins asserted under:%s | fullwidth admitted by:%s | rejected by:%s' " $LOCALES" "${_ADMITS:- (none)}" "${_REJECTS:- (none)}")"
printf '%s\n' "$_NOTE_LOCALES"
[ -n "$_ADMITS" ] || printf '  NOTE  no installed locale admits the fullwidth letter: the write-side collation pin CANNOT see its own failure here\n'

UID_FW="$(printf 'a\xef\xbd\x811')"   # a + FULLWIDTH LATIN SMALL LETTER A (U+FF41) + 1

test_start "a non-ASCII id is refused by the CLEAR side under every locale this box has"
for L in $LOCALES; do
  reset_all
  jq -nc --arg id "$UID_FW" '{redteam_pending:{($id):{ts:"2026-09-06T19:00:00Z",refs:[],sid:"s1"}}}' > "$CARE"
  jq -nc --arg id "$UID_FW" '{tool_name:"TaskStop", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
     tool_input:{task_id:$id}, tool_response:{task_id:$id, message:"Successfully stopped task"}}' \
    | LC_ALL="$L" bash "$RT" stamp
  assert_ne "$(jq -r --arg id "$UID_FW" '.redteam_pending[$id] // "gone"' "$CARE")" "gone" "[$L] a non-ASCII id is not an id here"
done

# The writer and the killer must answer the SAME question. If the writer is looser, it
# mints a key the killer can never match, and the wake names that lens forever.
test_start "…and the WRITE side refuses the same id under every locale, so the two cannot disagree"
for L in $LOCALES; do
  reset_all
  agent_launched "Adversarial lens" "Attack 7e36d82." "$UID_FW" | LC_ALL="$L" bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "[$L] no key the killer could never clear, and nothing else recorded either"
  assert_contains "$(cat "$(trace_path)")" "an id the guard refused" "[$L] the trace names the refusal, not a missing id"
done
# …and with LC_ALL ABSENT from the hook's environment, the locale carried by LANG. Every
# pin in this file set its locale with an env prefix, which EXPORTS it, and under an
# exported LC_ALL a bare `LC_ALL=C` assignment inside the hook updates the exported value
# and locks the guard inside the test; a caller that does not export it is the box where
# that guard ran ambient (the 35th lens, BLOCKING-2). Tip-green because the hook exports
# the locale itself now; red where a locale admits the letter and that export is gone. On
# a C-only runner this is vacuous, like every collation pin here, and the NOTE says so.
test_start "…and the WRITE side refuses it with LC_ALL absent from the caller's environment, under every locale LANG could carry (35th lens, BLOCKING-2)"
for L in $LOCALES; do
  reset_all
  agent_launched "Adversarial lens" "Attack 7e36d82." "$UID_FW" | env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG="$L" bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "[LANG=$L, no LC_ALL] no key the killer could never clear"
done

test_start "an ordinary hex agent id is still accepted under every locale"
for L in $LOCALES; do
  reset_all
  agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | LC_ALL="$L" bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "[$L] a real id still lands"
done


# ── THE 31ST LENS ─────────────────────────────────────────────────────────────
# BLOCKING-1: both intent regexes were unanchored STEMS. `port the` matched inside "report
# the", `migrate` inside "migration", `attack` inside "attackers", `audit` inside "auditor".
# Measured 09-07 over this box's own transcripts then held (a rolling window; the count is not
# reproducible later): 31 of 391 real dispatches were lenses the rail
# classified as builders and never recorded, about one in twelve (the lens counted 34;
# re-running its instrument gave 35, four of them implementers its own boundary check had
# mis-flagged). The 08-17 fix deleted ONE
# over-broad alternative (`build the`) and left the class in place.
test_start "a hostile brief that says 'report the assertion counts' is still a lens (31st lens, BLOCKING-1)"
reset_all
agent_launched "Adversarial lens on 7e36d82" "You are a hostile second lens. Attack 7e36d82. Run the mutants and report the assertion counts." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "'report the' is not 'port the'"

test_start "…nor does a lens on a migration, a refactored file or the scaffolding read as a builder"
for _brief in "Second lens on the migration state machine at 7e36d82" \
              "Adversarial lens on what migrated in 7e36d82" \
              "Lens on the implementers of 7e36d82" \
              "Adversarial lens on the implementation of 7e36d82"; do
  reset_all
  agent_launched "lens" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done

test_start "…and a lens word INSIDE a longer word does not make a builder into a lens"
for _brief in "Add attackers to the race game mode for 7e36d82" \
              "Add a judgement column to the invoice model for 7e36d82" \
              "Walk the auditor over the ledger for 7e36d82" \
              "Prejudged: wire the audition flow for 7e36d82"; do
  reset_all
  agent_launched "build" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done

test_start "…while a whole-word build verb still marks a builder even beside a lens word"
for _brief in "Migrate the ledger to sqlite, then judge the result at 7e36d82" \
              "Refactor the parser and attack it afterwards at 7e36d82" \
              "Implement the endpoint; a hostile pass comes later at 7e36d82" \
              "Refactoring the auth module at 7e36d82, then audit your own work" \
              "Adversarial review of the refactored parser at 7e36d82" \
              "Redteam the scaffolding under 7e36d82" \
              "Implementing the tokenizer at 7e36d82; attack it afterwards" \
              "Rebuild the pipelines for 7e36d82 and then attack it"; do
  reset_all
  agent_launched "build" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "builder first: $_brief"
done

# IMPORTANT-3: a THIRD guard minted pending keys — the text-fallback scrape at the launch
# branch used a bracket range, so under en_US.utf8 it minted the fullwidth id the killer
# refuses, and under C it TRUNCATED at the first non-member byte and minted `a` for an agent
# whose id is `aａ1`, which promote (keyed on the raw agent_id) can never match either.
test_start "the text-fallback id scrape asks the same question as the object path, under every locale (31st lens, IMPORTANT-3)"
for L in $LOCALES; do
  reset_all
  jq -nc --arg id "$UID_FW" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
     tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
     tool_response:[{type:"text", text:("Async agent launched successfully.\nagentId: " + $id + " (internal ID)")}]}' \
    | LC_ALL="$L" bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "[$L] no key the killer could never clear, and no truncated key either"
  assert_contains "$(cat "$(trace_path)")" "an id the guard refused" "[$L] the trace names the refusal"
done

test_start "…and a plain hex id through the text fallback still lands, under every locale"
for L in $LOCALES; do
  reset_all
  jq -nc --arg id "$AID" '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
     tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
     tool_response:[{type:"text", text:("Async agent launched successfully.\nagentId: " + $id + " (internal ID)")}]}' \
    | LC_ALL="$L" bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "[$L] a real id still lands"
done

# IMPORTANT-4: the 29th lens's IMPORTANT-1, alive 200 lines down. promote's bad-ending branch
# discarded maude_care_set's return and announced "pending entry cleared" against a store it
# could not write. Same fixture as the clear-side test above: a DIRECTORY where the lock
# wants a file.
test_start "a lens that ended badly against an unwritable store: the trace says could-not-clear, not cleared (31st lens, IMPORTANT-4)"
reset_all
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | bash "$RT" stamp
rm -rf "$CARE.lock"; mkdir "$CARE.lock"; chmod a-w "$(dirname "$CARE")"   # non-root (CI, macOS): the temp beside care.json cannot be made
jq -nc --arg id "$AID" '{hook_event_name:"SubagentStop", session_id:"sess1111-aaaa-bbbb", agent_id:$id, agent_type:"general-purpose", status:"failed"}' | bash "$RT" promote
chmod u+w "$(dirname "$CARE")"; rmdir "$CARE.lock" 2>/dev/null
TR="$(cat "$(trace_path)")"
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the entry really did survive"
assert_not_contains "$TR" "pending entry cleared" "the trace must NOT claim a clear"
assert_contains "$TR" "could not clear" "it says the store was unwritable"

# IMPORTANT-5: both failure belts were object-only, so a tool_response that is a bare STRING
# — the two real ones on this box are auto-mode classifier denials, captured 2026-08-09 —
# passed both and fell through to the synchronous stamp with real shas in its refs. The
# class: a stamp needs COMPLETION EVIDENCE, an object carrying content, agentType,
# totalDurationMs or status "completed". A string, an array of text blocks, or a bare object
# has none; it records nothing and says so.
test_start "a bare-string tool_response on a dispatch is not a completion: nothing stamped (31st lens, IMPORTANT-5)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
   tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."},
   tool_response:"Error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}' | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "the classifier ran nothing; the captured denial string stamps nothing"
assert_contains "$(cat "$(trace_path)")" "no completion evidence" "and the trace says why"

test_start "…nor is an array of text blocks or an evidence-less object a completion"
for _resp in '[{type:"text",text:"findings: 3"}]' '{}' '{foo:"bar"}'; do
  reset_all
  jq -nc "{tool_name:\"Agent\", hook_event_name:\"PostToolUse\", session_id:\"sess1111-aaaa-bbbb\",
     tool_input:{description:\"Adversarial lens\", prompt:\"Attack 7e36d82.\"}, tool_response:$_resp}" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing stamped for tool_response $_resp"
done

test_start "…while the captured completion envelope still stamps (control)"
reset_all
agent_done "Adversarial lens" "Attack 7e36d82." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "7e36d82" "a real completion stamps"

# MINOR-4a: the REFS scrape was a fourth locale-dependent bracket range: under en_US.utf8
# `[0-9a-f]{7,40}` admitted a hex run with an Arabic-Indic tail and a garbage ref took a
# slot in the 64-ref cap and the 128-entry window.
test_start "a ref-shaped token with a non-ASCII tail never lands in the stamp, under every locale (31st lens, MINOR-4a)"
for L in $LOCALES; do
  reset_all
  agent_done "Adversarial lens" "Attack 7e36d82 and 1c893d3 and $(printf '7e36d8\xd9\xa1') tail." | LC_ALL="$L" bash "$RT" stamp
  assert_eq "$(read_care '.last_redteam_iso.default.refs | map(select(test("^[0-9a-f]{7,40}$") | not)) | length')" "0" "[$L] every recorded ref is plain hex"
  assert_contains "$(read_care '.last_redteam_iso.default.refs | join(",")')" "1c893d3" "[$L] the real refs are still there"
done


# Every alternative this round ADDED or WIDENED, pinned by a brief that matches through it
# and nothing else — so deleting that alternative from the hook goes red here (proved by
# mutation, one alternative at a time: mut31-*.txt, the author's logs, off-tree). The negative
# tests above cannot see an alternative's absence; these can.
test_start "each widened adversarial alternative is pinned: a brief that matches only through it is recorded"
for _brief in "Claims lens on the release text at 7e36d82" \
              "Lens 3: run it like an enduser at 7e36d82" \
              "Redteamed 7e36d82: list what its tests could not see" \
              "Red-teaming 7e36d82 before it ships" \
              "Read 7e36d82 adversarially and list what gives" \
              "Attacking the parser at 7e36d82" \
              "Auditing 7e36d82 for the class of the last bug" \
              "Judging the cadence of 7e36d82" \
              "Critiqued: 7e36d82, every weak claim listed" \
              "Refutes the counts in 7e36d82 one by one" \
              "Falsifies the claims in 7e36d82"; do
  reset_all
  agent_launched "lens" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done

test_start "…and the widened build verb is pinned: 'rebuild the pipeline' beside a lens word is a builder"
reset_all
agent_launched "build" "Rebuild the pipeline for 7e36d82 and then attack it" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "builder first: rebuild the pipeline"


# ── THE 32ND LENS ─────────────────────────────────────────────────────────────
# BLOCKING-2: the whole-word boundary is a bracket range, and the two intent greps ran under
# the ambient locale. Under en_US.utf8 a non-ASCII LETTER glued to a listed word collates
# inside a-z and is not a boundary, so BOTH regexes miss: a builder can stamp, a lens goes
# uncredited. Bytes, like every other guard in this file.
test_start "a non-ASCII letter glued to a build word is still a boundary, under every locale (32nd lens, BLOCKING-2)"
for L in $LOCALES; do
  reset_all
  agent_launched "build" "$(printf '\xef\xbd\x92')refactor the parser at 7e36d82 and attack it" "$AID" | LC_ALL="$L" bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "[$L] a fullwidth letter before the build verb does not hide it"
done
# The same with LC_ALL absent from the caller's environment: the shape that exposed a bare
# `LC_ALL=C` assignment inside the hook as no lock at all (the 35th lens, BLOCKING-2; the
# comment on the write-side id pin above says why an env prefix could not see it).
test_start "…and with LC_ALL absent from the caller's environment, under every locale LANG could carry (35th lens, BLOCKING-2)"
for L in $LOCALES; do
  reset_all
  agent_launched "build" "$(printf '\xef\xbd\x92')refactor the parser at 7e36d82 and attack it" "$AID" | env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG="$L" bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "[LANG=$L, no LC_ALL] a fullwidth letter before the build verb does not hide it"
done
test_start "…and glued to a lens word it is still a boundary, under every locale"
for L in $LOCALES; do
  reset_all
  agent_launched "lens" "Read 7e36d82: $(printf '\xef\xbd\x81')attack it with fresh eyes" "$AID" | LC_ALL="$L" bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "[$L] a fullwidth letter before the lens word does not hide it"
done

# IMPORTANT-6 (32nd): "completion evidence" tested PRESENCE, not evidence: an empty content,
# an empty agent type, a zero duration all stamped a full pass. BLOCKING-1 (33rd): the fix
# left `status:"completed"` sufficient on its own, and every real completion on this box
# carries it, so the fixtures below were green only because they OMITTED a field the
# harness has never once omitted. Every fixture carries the captured shape now, and evidence
# is a non-blank text: an empty or whitespace block, a block with no text, or `[null]` is
# not something an agent returned.
test_start "an empty-valued evidence field beside status \"completed\" is not evidence: nothing stamped (32nd lens IMPORTANT-6, 33rd lens BLOCKING-1)"
for _resp in '{content:[], status:"completed"}' '{content:"", status:"completed"}' \
             '{totalDurationMs:0, status:"completed"}' '{agentType:"", status:"completed"}' \
             '{content:[], agentType:"", totalDurationMs:0, status:"completed"}' \
             '{content:[], agentType:"", totalDurationMs:0, status:"completed", agentId:"x1"}' \
             '{content:[{type:"text", text:""}], agentType:"general-purpose", totalDurationMs:123, status:"completed"}' \
             '{content:[{type:"text", text:" "}], status:"completed"}' \
             '{content:[{type:"text"}], status:"completed"}' \
             '{content:[null], status:"completed"}' \
             '{content:" ", status:"completed"}'; do
  reset_all
  jq -nc "{tool_name:\"Agent\", hook_event_name:\"PostToolUse\", session_id:\"sess1111-aaaa-bbbb\",
     tool_input:{description:\"Adversarial lens\", prompt:\"Attack 7e36d82.\"}, tool_response:$_resp}" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing stamped, nothing pending, for tool_response $_resp"
done
test_start "…and an error flag in either spelling refuses a completion that carries text (33rd lens, MINOR-2)"
for _resp in '{content:[{type:"text", text:"boom"}], status:"completed", isError:true}' '{content:[{type:"text", text:"boom"}], status:"completed", is_error:true}'; do
  reset_all
  jq -nc "{tool_name:\"Agent\", hook_event_name:\"PostToolUse\", session_id:\"sess1111-aaaa-bbbb\",
     tool_input:{description:\"Adversarial lens\", prompt:\"Attack 7e36d82.\"}, tool_response:$_resp}" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing stamped for $_resp"
  assert_contains "$(cat "$(trace_path)")" "reported an error" "the trace names the error for $_resp"
done
test_start "…while non-empty content alone is evidence (control)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
   tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."}, tool_response:{content:[{type:"text",text:"findings: 0"}]}}' | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso.sess1111.refs | join(",")')" "7e36d82" "content with text stamps"

# MINOR-5: promote's bad-ending branch announced "pending entry cleared" for an id nothing
# had launched. Nothing pending is its own sentence.
test_start "a bad ending for an id that was never pending says so, and does not claim a clear (32nd lens, MINOR-5)"
reset_all
jq -nc '{redteam_pending:{someoneelse:{ts:"2026-09-07T19:00:00Z",refs:[],sid:"s9"}}}' > "$CARE"
jq -nc '{hook_event_name:"SubagentStop", session_id:"sess1111-aaaa-bbbb", agent_id:"neverlaunched1", agent_type:"general-purpose", status:"failed"}' | bash "$RT" promote
TR="$(cat "$(trace_path)")"
assert_not_contains "$TR" "pending entry cleared" "no clear was made, so none is claimed"
assert_contains "$TR" "nothing was pending" "it says what it found"
assert_eq "$(read_care '.redteam_pending | keys | join(",")')" "someoneelse" "and the other session's entry is untouched"

test_start "…and a store that cannot be READ is not a store that said no (33rd lens, IMPORTANT-5)"
reset_all
printf '{' > "$CARE"
jq -nc '{hook_event_name:"SubagentStop", session_id:"sess1111-aaaa-bbbb", agent_id:"neverlaunched1", agent_type:"general-purpose", status:"failed"}' | bash "$RT" promote
TR="$(cat "$(trace_path)")"
assert_not_contains "$TR" "nothing was pending" "a failed read is not a fact about the store"
assert_contains "$TR" "could not clear" "the broken store is named instead"
assert_contains "$TR" "could not be read or written" "and named for what it is: a torn store is writable (34th lens, MINOR-2)"

# MINOR-6: the `^` half of the boundary was pinned only sideways. A brief whose FIRST word is
# the lens word is recorded, by design. (A guard: the old stems also saw it.)
test_start "a brief whose first word is the lens word is recorded (32nd lens, MINOR-6)"
reset_all
agent_launched "Attack" "7e36d82 with fresh eyes" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the ^ boundary counts"

# BLOCKING-1 was live in the corpus, not only constructed. The replay that chose the
# inflections held one build brief ("You are builder B3 … builder b1 is implementing it in
# parallel … judge.py and embedder.py", 2026-08-13) that 4021ec3 AND 8782231 (internal-tree shas) both read as a
# lens: `judge.py` is the whole word `judge` to a boundary that stops at the dot, and
# neither builder list had `implementing`. The round's own tally filed it among four lost
# lenses; it was the false stamp the finding described.
test_start "a build brief that names judge.py and says 'is implementing' records nothing (32nd lens, BLOCKING-1 in the corpus)"
reset_all
agent_launched "Build capture hook + egress tripwire (B3)" "You are builder B3 for the plugin. Your job: the capture hook script and the no-default-egress tripwire test. Builder b1 is implementing the stub in parallel. The files that must never import a socket are judge.py and embedder.py; assert both." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "a builder whose brief names judge.py is not a lens"

# ── THE 33RD LENS ─────────────────────────────────────────────────────────────
# IMPORTANT-2: `implemented` was added on a raw frequency and refused no builder the list did
# not already refuse, at the cost of two review briefs. A past tense is a description.
test_start "a review brief that says the author 'implemented' something is recorded (33rd lens, IMPORTANT-2)"
reset_all
agent_launched "lens" "The author implemented the tokenizer at 7e36d82; attack it" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "past tense is not a build order"
# …and the noun that sixteen review briefs on this box use for the person whose work they
# review: "the implementer's report". Same ledger, measured by the author after the report.
test_start "…and a review brief that names 'the implementer's report' is recorded (same ledger, the author's own row)"
reset_all
agent_launched "Review Task 2" "Read the implementer's report, then judge the fix at 7e36d82 against the brief" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "a noun for the reviewed party is not a build order"
# …and the door that removal opened is closed by the CLASS, not the noun (the 34th lens,
# BLOCKING-2): "you are"/"as", an optional article, up to two modifiers, then implementer
# or builder; and a review verb before "your own work". Both phrases fire on no build brief
# this box has not already refused; their only corpus cost is this rail's own briefs, which
# quote them to describe the trap, and those are spelled around it. The 35th (IMPORTANT-1)
# found the first phrase was not a TITLE test: it fired on "you are not the builder" and on
# "reviewing the builder's work", the plainest ways this house addresses a lens, and the
# second on "do not audit your own work". A title is not negated and not possessive now,
# and a negated self-review is not an order. The closed set stops there: "never", "no",
# "now the builder" still read as a title or an order, named below.
test_start "…and a brief that titles its own agent the implementer, then asks it to audit its own work, records nothing (34th lens, BLOCKING-2)"
reset_all
agent_launched "tokenizer" "You are the implementer of the tokenizer at 7e36d82; audit your own work" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "a self-titled implementer is a builder"
test_start "…nor does the hook's own cited negative, two modifiers deep: 'a careful TDD implementer ... judge your own work'"
reset_all
agent_launched "Build 7e first-light wiring TDD" "You are a careful TDD implementer. Wire it, then judge your own work at 7e36d82" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "the file's own motivating negative records nothing"
test_start "…nor a self-titled builder with a review word and no listed object"
reset_all
agent_launched "Build profile + voice report (B2)" "You are builder B2 on branch x. Wire the report, then attack it at 7e36d82" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "'you are builder' is a build order"
test_start "…nor a brief with no self-title at all that asks the agent to review its own work (the self-review phrase alone)"
reset_all
agent_launched "wiring" "Wire the report at 7e36d82, then judge your own work" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "'your own work' is a build order on its own"
test_start "…and a slash BETWEEN two review words is a path by shape ('critique/attack'), by design: refused, named here; CONSTRUCTED, no captured row (35th lens, IMPORTANT-3)"
reset_all
agent_launched "seams" "Read 7e36d82; critique/attack the seams" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "known and stated: 'critique/attack' has the shape of estate-CI/canon-audit"
test_start "…and the two-word modifier slot over-reaches on 'a lens on builder B3', by design: a lens uncredited, corpus zero, named here"
reset_all
agent_launched "fix review" "You are a lens on builder B3's fix at 7e36d82; break it" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "known and stated: 'lens on builder' fills the two-word slot"
test_start "…and the slot stops at two: a title with THREE modifiers is not read as one, by design, named (37th lens, MINOR-1)"
reset_all
agent_launched "pass" "You are the two careful lead builders of 7e36d82; then attack it." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "known and stated: three modifiers overrun the slot (corpus: one row carries such a title, this rail's own 34th brief)"
test_start "…while a lens ON the implementer's fix is still recorded (the modifier slot must not swallow 'lens on the')"
reset_all
agent_launched "fix review" "You are a lens on the implementer's fix at 7e36d82; break it" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "a lens on someone else's work is a lens"
# IMPORTANT-1 (35th): the shapes the class refused for one round. Every brief below is
# constructed: none of the 405 dispatches measured 2026-09-10 05:2xZ (a 30-day transcript
# window, 2026-08-11..2026-09-10; scan33.py and scan36a-keys.txt, off-tree) carries any of
# them. A corpus count is a measurement with a time and a window, never a fact.
test_start "an agent told it is NOT the builder is not a builder (35th lens, IMPORTANT-1)"
for _brief in "You are not the builder here; attack 7e36d82" \
              "You are not the implementer; judge 7e36d82" \
              "You are the reviewer not the builder at 7e36d82: attack it"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…nor an agent reviewing the BUILDER'S work: a possessive is an object, not a title"
for _brief in "You are reviewing the builder's work at 7e36d82; break this" \
              "Read 7e36d82 as the builder's peer; find the gaps"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…nor an agent told NOT to review its own work"
for _brief in "Do not audit your own work; audit the author's at 7e36d82" \
              "Don't judge your own diff; judge 7e36d82"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…while a title that is neither negated nor possessive is still a builder"
for _brief in "You are the builder. Break it at 7e36d82" \
              "You are now the builder at 7e36d82; attack it" \
              "Read it as builder B3 would at 7e36d82"; do
  reset_all
  agent_launched "build" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "a builder: $_brief"
done
# BLOCKING-2 (36th): the title class stopped at the singular. "You are builders B1 and B2"
# and "You are the implementers" wrote full stamps naming the tip; the noun takes a plural
# now. The two laws in the hook disagree here and the asymmetry law decided it: the marginal
# ledger refuses no build brief the list did not already refuse and costs one lens (this
# rail's own 35th brief, which quotes the plural to describe this trap); a false stamp is
# the failure that matters. The possessive exclusion still holds for the plural.
test_start "a PLURAL title is a title: 'you are builders' and 'as implementers' are build orders (36th lens, BLOCKING-2)"
for _brief in "You are builders B1 and B2 at 7e36d82; then attack it." \
              "You are the implementers; wire the pipeline at 7e36d82 and attack it." \
              "As implementers of 7e36d82, wire it then judge it."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "a builder: $_brief"
done
test_start "…while a plural POSSESSIVE is how a lens is addressed: 'the builders' work' is still recorded"
for _brief in "You are reviewing the builders' work at 7e36d82; break this" \
              "You are our builders' lead at 7e36d82; attack it"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…and the closed set stops at 'not' and \"don't\": 'never' still reads as a title or an order, by design"
for _brief in "You are never the builder here; attack 7e36d82" \
              "Never audit your own work; audit 7e36d82"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "known and stated: $_brief"
done
test_start "…and a 'not' one word further from the verb is still an order, by design: named (36th lens, MINOR-4)"
for _brief in "You are not to audit your own work at 7e36d82; attack the spec" \
              "Do not, under any circumstances, audit your own work; attack 7e36d82's spec"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "known and stated: $_brief"
done

# IMPORTANT-1: MINOR-6 pinned the `^` half of the boundary; the `|$` half had no pin, and
# without it a brief ENDING on a listed word is hidden from both lists.
test_start "a brief whose LAST word is the lens word is recorded (33rd lens, IMPORTANT-1)"
reset_all
agent_launched "pass" "Read 7e36d82 then attack" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the \$ boundary counts on the lens side"
test_start "…and a brief whose LAST word is a build word records nothing"
reset_all
agent_launched "pass" "Attack 7e36d82 after you refactor" "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "the \$ boundary counts on the builder side"

# BLOCKING-3 (34th): `-`, `.` and `/` were boundaries on the review side too, so `redteam`
# inside this hook's own file name and `audit` inside the pre-push guard's `leak-audit`
# marker credited a dispatch that reviewed nothing: three captured non-review briefs wrote
# a full stamp when replayed. A review word glued to an identifier by `-`, `.` or `/` is
# part of the identifier now; a prose review word, hyphenated `red-team` included, still
# credits. (A `release_leak_audit.py` brief sat in this loop for one round: an underscore
# was always a boundary refusal, so that fixture was green at every sha and under every
# mutant, and the comment beside it claimed a credit that never happened. The 35th lens,
# IMPORTANT-2; gone.)
test_start "a review word inside an identifier is not a review word: the hook's own file name (34th lens, BLOCKING-3)"
reset_all
agent_launched "hook edit" "Edit maude-redteam-watch.sh so the trace line carries the sha at 7e36d82." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "naming this hook is not a redteam pass"
test_start "…nor 'leak-audit' or 'canon-audit', an identifier's own hyphen"
for _brief in "Apply the swept edits at 7e36d82. Expect leak-audit: CLEAN." \
              "Inventory every repo at 7e36d82 for the estate-CI/canon-audit."; do
  reset_all
  agent_launched "apply" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done
test_start "…while the same words in prose, and a hyphenated red-team, still credit"
for _brief in "Audit the ledger at 7e36d82 line by line." \
              "Red-team the sentinel at 7e36d82." \
              "Redteam 7e36d82: break this."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
# …and on the RIGHT of a review word a full stop, a hyphen or a slash is GLUE only when a
# letter or digit follows it. Sentence punctuation still bounds: the first cut of this
# boundary refused every review word that ended a sentence (the 34th round's own review,
# before the push), which is the most ordinary English there is and a lens uncredited every
# time.
test_start "…and sentence punctuation beside a review word still bounds it (a period is not an identifier)"
for _brief in "Read 7e36d82 then attack." \
              "Read 7e36d82. Then judge." \
              "Please red-team it at 7e36d82." \
              "Read 7e36d82--then judge--every claim."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
# BLOCKING-1 (35th): on the LEFT the 34th's second cut bounded `-`, `.` or `/` whenever a
# NON-word character preceded them, which is the shape of a CLI flag and of a dotfile: "Add
# a --audit flag" wrote a full review stamp naming the tip. And it still refused an English
# prefix: "Re-audit the ledger" recorded nothing. A hyphen glues now unless what precedes it
# is one of a CLOSED set of prefixes (re-, self-, pre-, post-, counter-), each pinned below;
# identifiers are an open vocabulary. Every brief below is constructed: of the 405
# dispatches measured 2026-09-10 05:2xZ (window 2026-08-11..2026-09-10, scan33.py and
# scan36a-keys.txt, off-tree), the rows that carry any of these shapes, in either
# direction, are this rail's own 35th and 36th briefs (99539428:3335, 8de87643:565), which
# quote them to describe this trap and are credited through other words.
test_start "a brief that asks for a --audit FLAG to be built writes no stamp at completion (35th lens, BLOCKING-1)"
reset_all
agent_done "Add a CLI flag" "Add a --audit flag to the CLI at 7e36d82 and wire it to the reporter." | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "a flag is not a review word"
test_start "…and the control that must fire: the same brief with a review verb appended writes the stamp"
reset_all
agent_done "Add a CLI flag" "Add a --audit flag to the CLI at 7e36d82 and wire it to the reporter, then audit it." | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso | tostring')" "7e36d82" "the control stamps, with the ref"
test_start "…and a flag, a dotfile or a lone leading hyphen before a review word records nothing on the launch path"
for _brief in "Run the tool with --audit at 7e36d82" \
              "Run scripts/check --judge 7e36d82" \
              "Open .audit and read it at 7e36d82" \
              "Read 7e36d82 -attack it"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done
test_start "…while an English prefix on a review word is the review word (the mirror the second cut missed)"
for _brief in "Re-audit the ledger at 7e36d82." \
              "Self-audit the ledger at 7e36d82." \
              "Pre-audit the release at 7e36d82." \
              "Post-audit the release at 7e36d82." \
              "Counter-attack the fix at 7e36d82." \
              "Read 7e36d82 and re-judge the claim." \
              "Read 7e36d82, then re-attack the seams."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…and an identifier's own hyphen still glues: pip-audit, shape-audit"
for _brief in "Run pip-audit against 7e36d82's lockfile." \
              "Run the shape-audit at 7e36d82 and paste its table."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done
test_start "…and two shapes refused by design, named: a negating prefix, and a double hyphen glued to the word's front"
for _brief in "Non-adversarial sweep of 7e36d82." \
              "fix--attack it at 7e36d82"; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "known and stated: $_brief"
done
# BLOCKING-1 (36th): the 35th's cut refused a FLAG and left every other way code marks a
# token open: "--mode=audit", a backticked `audit`, "audit()", "[audit]", a quoted "audit"
# and "MODE:audit" each wrote a full stamp naming the tip. The class is a review word that
# is a TOKEN in code, and code marks a token with a quotation mark, a bracket, a brace, an
# assignment, a call or a sigil, on either side. The 36th listed what glues and the 37th
# found the next character (BLOCKING-1 below); the boundary names what BOUNDS now and
# everything else glues. A CLOSING mark or a colon still bounds: "(then attack)" is an
# order in parentheses, and "Lens 3:" is how this house numbers a pass, credited by its
# digit with the colon after it.
test_start "a review word that is a TOKEN in code is not a review word: eight build briefs write no stamp at completion (36th lens, BLOCKING-1)"
for _brief in 'Add --mode=audit to the CLI at 7e36d82 and wire it to the reporter.' \
              'Add the `audit` subcommand at 7e36d82 and wire it.' \
              'Add an audit() helper at 7e36d82.' \
              'Add the [audit] section to config.toml at 7e36d82.' \
              'Add "audit" to the allowed modes list at 7e36d82 and wire it.' \
              "Add 'judge' to the enum at 7e36d82 and wire it." \
              'Wire MODE:audit into the CLI at 7e36d82.' \
              'Set audit=true in settings at 7e36d82 and wire it.'; do
  reset_all
  agent_done "Add a mode" "$_brief" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done
test_start "…and the control that must fire: the same brief with a review verb appended writes the stamp"
reset_all
agent_done "Add a mode" 'Add --mode=audit to the CLI at 7e36d82 and wire it to the reporter, then audit it.' | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso | tostring')" "7e36d82" "the control stamps, with the ref"
test_start "…while a closing mark or a colon after a review word still bounds it: a numbered lens, an order in brackets"
for _brief in "Lens 3: run it like an enduser at 7e36d82" \
              "Read 7e36d82 (then attack)." \
              "Read 7e36d82 [then judge]."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…and three shapes decided by the class and named: a review word that OPENS a bracket or a quotation is refused, one before a colon is still credited"
for _brief in "Read 7e36d82 (attack every claim)." \
              'Run "audit" on the parser at 7e36d82.'; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "known and stated: $_brief"
done
reset_all
agent_launched "pass" "Wire up audit: the new mode at 7e36d82." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "known and stated: a colon after a review word bounds it, the price of 'Lens 3:'"
# BLOCKING-1 (37th): the 36th's cut listed what GLUES (a quotation mark, a bracket, a brace, an
# assignment, a call) and a SIGIL is how code marks a token too: "@audit", "$audit", "<audit>",
# "#audit", "%audit%", "*audit", "&audit", "~audit" each wrote a full stamp naming the tip. A
# glue list always has a next character. The boundary is stated the right way round now, as
# what BOUNDS: on the left the start of the text, whitespace, a comma or semicolon, a closing
# mark, a non-ASCII byte (the 32nd's law: a non-ASCII letter glued to a listed word is still a
# boundary, on both sides), a double asterisk (markdown emphasis: 6 of the 366 rows held
# at 08:55Z 2026-09-11 bold a review word on its left, 2 on its right, none credited only
# so; scan37a-cff8d7a-to-work.txt, off-tree), and the closed English-prefix rule; on
# the right the end, whitespace, sentence punctuation (, ; : ! ?), a closing mark, a non-ASCII
# byte, a double asterisk, and a dot, hyphen or slash followed by a non-word. Everything else
# glues, sigils included, and no future sigil needs a new character. Named residuals: a curly
# quotation mark is a non-ASCII byte and so a bound (a mention in curly quotes credits); a lone
# asterisk glues (single-star emphasis around a lone review word loses credit).
test_start "a SIGIL is how code marks a token too: ten sigil build briefs write no stamp at completion (37th lens, BLOCKING-1)"
for _brief in 'Add the @audit decorator at 7e36d82 and wire it.' \
              'Add the $audit variable at 7e36d82 and wire it.' \
              'Add the <audit> element at 7e36d82 and wire it.' \
              'Add the #audit tag at 7e36d82 and wire it.' \
              'Add the %audit% token at 7e36d82 and wire it.' \
              'Add the *audit pointer at 7e36d82 and wire it.' \
              'Add the &audit reference at 7e36d82 and wire it.' \
              'Add the ~audit rule at 7e36d82 and wire it.' \
              'Add >audit to the pipeline at 7e36d82 and wire it.' \
              'Add the ?audit query at 7e36d82 and wire it.'; do
  reset_all
  agent_done "Add a mode" "$_brief" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "nothing recorded: $_brief"
done
test_start "…and the control that must fire: the same brief with a review verb appended writes the stamp"
reset_all
agent_done "Add a mode" 'Add the @audit decorator at 7e36d82 and wire it, then audit it.' | bash "$RT" stamp
assert_contains "$(read_care '.last_redteam_iso | tostring')" "7e36d82" "the control stamps, with the ref"
test_start "…while the bounds prose puts beside a review word still bound it: bold emphasis, an em dash, sentence punctuation, a second lens"
for _brief in "Read 7e36d82 and **attack** every claim." \
              "Read 7e36d82$(printf '\xe2\x80\x94')attack every claim." \
              "Read 7e36d82; attack, then judge!" \
              "Read 7e36d82; then judge? Yes." \
              "Second lens on 7e36d82."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded: $_brief"
done
test_start "…and the shapes the class decides, named: single-star emphasis, a ~~ pair, an unpadded table cell and a spaceless blockquote glue; a quoted ORDER is a quotation; a curly quotation mark is a non-ASCII bound"
for _brief in "Read 7e36d82 and *attack* every claim." \
              "Read 7e36d82 and ~~attack~~ every claim." \
              "Read 7e36d82 |audit| every claim." \
              ">attack every claim in 7e36d82." \
              'He said "attack it." Read 7e36d82.'; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_eq "$(read_care '.')" "{}" "known and stated: $_brief"
done
reset_all
agent_launched "pass" "Read 7e36d82 and $(printf '\xe2\x80\x9c')attack$(printf '\xe2\x80\x9d') every claim." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "known and stated: a curly quotation mark is a non-ASCII byte, a bound the byte class cannot tell from a letter"
# IMPORTANT-2 (37th): the apostrophe was the one piece of the class that cost a corpus row and
# the one piece with no pin.
test_start "a review noun's possessive is a mention, not an order: 'the audit's finding' records nothing (37th lens, IMPORTANT-2)"
reset_all
agent_launched "pass" "Read the audit's finding at 7e36d82 and scope the lane." "$AID" | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "known and stated: a possessive after a review noun glues"
test_start "…and the control: the same brief with an order appended is recorded"
reset_all
agent_launched "pass" "Read the audit's finding at 7e36d82 and attack it." "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "recorded through the order, not the mention"
# The residual, named as a CLASS: a review word that is a bare token in code, with nothing
# but whitespace around it, is a whole word the vocabulary cannot tell from prose. A CLI
# subcommand ("release_leak_audit.py audit | tail -1"; one captured brief on this box is
# credited that way, an apply task), a flag's VALUE after a space ("--mode audit"; the 36th
# closed "--mode=audit" and left this one open: the 37th lens, IMPORTANT-3), a bare mode name
# ("mode audit") and a directory with its slash then a space ("audit/ ") all credit. By design
# until a better discriminator exists; every shape is pinned below as recorded and named.
test_start "…and a bare 'audit' as a CLI subcommand is still a review word: the one named residual, by design"
reset_all
agent_launched "apply" "Apply the pre-approved edits at 7e36d82, then run: python3 scripts/release_leak_audit.py audit | tail -1" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "known and stated: one captured row"
test_start "…and the rest of the bare-word class, named: a flag's value after a space, a bare mode name, a directory with its slash"
for _brief in "Run the tool with --mode audit at 7e36d82 and wire it." \
              "Add mode audit to the CLI at 7e36d82 and wire it." \
              "Add the audit/ directory at 7e36d82 and move the reports in."; do
  reset_all
  agent_launched "pass" "$_brief" "$AID" | bash "$RT" stamp
  assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "known and stated: $_brief"
done

# IMPORTANT-2 (34th): the async fallback minted a pending entry for an object the evidence
# gate had just judged empty, because it carried an agentId and no completed status. Every
# real launch carries status "async_launched"; a launch has no content at all.
test_start "an object with content the gate refused, an agentId and no status is not a launch: nothing pending (34th lens, IMPORTANT-2)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
   tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."}, tool_response:{content:{text:"findings: 0"}, agentId:"zz9"}}' | bash "$RT" stamp
assert_eq "$(read_care '.')" "{}" "no pending entry that nothing would clear"
test_start "…while a bare {agentId} with nothing else is still read as a launch (control)"
reset_all
jq -nc '{tool_name:"Agent", hook_event_name:"PostToolUse", session_id:"sess1111-aaaa-bbbb",
   tool_input:{description:"Adversarial lens", prompt:"Attack 7e36d82."}, tool_response:{agentId:"zz8"}}' | bash "$RT" stamp
assert_ne "$(read_care '.redteam_pending["zz8"] // "gone"')" "gone" "a bare id is a launch"

# MINOR-8 (34th): the ref scrape admits an all-digit run as a ref. It stays: fifteen of this
# repo's own short shas are all digits (8782231, an internal-tree sha, was a pushed tip), so a scrape-time filter
# would drop real refs. The reader's side (ship.sh) resolves refs; a decimal that is no commit
# matches nothing there. Named, not changed.
test_start "an all-digit run is still scraped as a ref, because real short shas are (34th lens, MINOR-8, by design)"
reset_all
agent_launched "pass" "Attack 8782231 and 7e36d82; the identity line is 271895126+john." "$AID" | bash "$RT" stamp
assert_contains "$(read_care ".redteam_pending[\"$AID\"].refs | join(\",\")")" "8782231" "an all-digit real sha lands"

# MINOR-8: `lens (on|[0-9])` is a review noun in this house (0 camera contexts in the 403 real
# dispatches held on 09-08, then-held window, not reproducible later; three review briefs were
# credited through it alone). A build brief with NO build
# verb that names a camera lens is recorded, by design; the next round that changes the
# alternative learns here what it is trading.
test_start "a brief with no build verb that names a camera 'lens 2' is recorded: not disambiguated, by design (33rd lens, MINOR-8)"
reset_all
agent_launched "cam work" "Fit camera lens 2 to the hood mount at 7e36d82" "$AID" | bash "$RT" stamp
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the residual is known and stated"

# BLOCKING-2 (33rd): on a runner with C and C.utf8 alone (gitea CI), no locale admits the
# fullwidth letter, so every collation pin above passes for a TRUE reason and cannot see its
# guard removed: five byte-locale guards in the hook were mutation-blind there, at "189
# passed, 0 failed", byte-identical to the healthy line. The 33rd pinned the SOURCE (each
# guard's text once in the comment-stripped body); the 34th (BLOCKING-1) showed a guard
# deleted from the executing line and left in a TRAILING comment satisfies that, and pinned
# the RUN instead: each guard's command line once, with `LC_ALL=C` on the xtrace line before
# it. The 35th (BLOCKING-2) showed THAT pin was on the mechanism: a bare `LC_ALL=C` on its
# own line prints the same trace as an env prefix and exports nothing, so an ordinary
# tidy-up left this file green with the guard running under the CALLER'S locale. The hook
# exports the locale ONCE at its top now, and this pin asserts that, in both traces: the
# export runs before the first guard and before the shared helper is sourced; no traced
# line, in a NAMED list of spellings (`_XT_TAMPER` and the `VAR=` count below; bash has
# more: the 36th lens showed `declare +x` un-exporting and `+=` reassigning with every line
# here green, IMPORTANT-1), assigns a locale variable anything but C (the shared helper's
# inner `LC_ALL=C` prefix is allowed, in either trace form), unsets one, un-exports one, or
# strips one with `env`; and each guard's command line runs exactly once. That list is a
# belt on the trace, not the property. The PROPERTY, that the guards RECEIVED LC_ALL=C, is
# asserted by the environment pin that follows, which reads what `grep` and `tr` were handed
# and not what the trace printed. None of it depends on how xtrace prints an assignment
# prefix, which the 34th's form did (bash 5 prints it on its own line; bash 3.2 was not run
# here: the 35th, IMPORTANT-4). A comment, a string, or a `:` no-op does not run, so it
# does not count. Provable on C alone, both pins.
xt_norm() { sed 's/^+* *//' "$1"; }   # strip the PS4 depth markers
xt_lines() {   # $1 = xtrace file, $2 = command prefix; counts traced commands that start with it
  xt_norm "$1" | awk -v pat="$2" 'index($0,pat)==1 {n++} END{print n+0}'
}
xt_export_before() {   # $1 = xtrace file, $2 = a guard's prefix; 1 iff `export LC_ALL=C` is traced before it
  xt_norm "$1" | awk -v pat="$2" '$0=="export LC_ALL=C" && !e {e=NR} index($0,pat)==1 && !g {g=NR} END{print (e && g && e<g) ? 1 : 0}'
}
_XT_TAMPER='(^| )(unset|export -n|declare \+x|typeset \+x|declare -n|printf -v|read( -[a-z]+)*) .*(LC_|LANG)|env (-i|-u ?LC_|-u ?LANG|--unset=(LC_|LANG))| (LC_[A-Z]+|LANG)=[^C]| (LC_[A-Z]+|LANG)=C[^ ]|^(LC_[A-Z]+|LANG)\+='
test_start "the byte-locale guards RUN under the hook's own LC_ALL=C export, each once, and nothing between reassigns it (a runtime pin, red on every runner: 34th lens BLOCKING-1, 35th lens BLOCKING-2)"
reset_all
XT_STAMP="$TEST_TMP/xtrace-stamp.txt"; XT_STOP="$TEST_TMP/xtrace-stop.txt"
agent_launched "Adversarial lens" "Attack 7e36d82." "$AID" | PS4='+ ' bash -x "$RT" stamp 2> "$XT_STAMP"
assert_ne "$(read_care ".redteam_pending[\"$AID\"] // \"gone\"")" "gone" "the traced launch still records (the trace changed nothing)"
task_stopped "$AID" | PS4='+ ' bash -x "$RT" stamp 2> "$XT_STOP"
assert_eq "$(xt_lines "$XT_STAMP" "export LC_ALL=C")" "1" "the export runs once on the stamp path"
assert_eq "$(xt_export_before "$XT_STAMP" "tr '[:upper:]' '[:lower:]'")" "1" "…before the first guard"
assert_eq "$(xt_lines "$XT_STOP" "export LC_ALL=C")" "1" "the export runs once on the clear path"
assert_eq "$(xt_export_before "$XT_STOP" "maude_is_ascii_token $AID")" "1" "…before the clear-side id guard"
assert_eq "$(xt_norm "$XT_STAMP" | grep -cE '^(LC_[A-Z]+|LANG)=' | cat)" "$(xt_norm "$XT_STAMP" | grep -cE '^LC_ALL=C( |$)' | cat)" "no traced line on the stamp path assigns a locale variable anything but C"
assert_eq "$(xt_norm "$XT_STAMP" | grep -cE -- "$_XT_TAMPER" | cat)" "0" "…and none unsets, un-exports, strips or overrides one"
assert_eq "$(xt_norm "$XT_STOP" | grep -cE '^(LC_[A-Z]+|LANG)=' | cat)" "$(xt_norm "$XT_STOP" | grep -cE '^LC_ALL=C( |$)' | cat)" "no traced line on the clear path assigns a locale variable anything but C"
assert_eq "$(xt_norm "$XT_STOP" | grep -cE -- "$_XT_TAMPER" | cat)" "0" "…and none unsets, un-exports, strips or overrides one"
assert_eq "$(xt_lines "$XT_STAMP" "tr '[:upper:]' '[:lower:]'")" "1" "runs once under the export: the lowercasing tr"
assert_eq "$(xt_norm "$XT_STAMP" | awk 'index($0,"grep -qE -- ")==1 && index($0,"(implement ")>0 {n++} END{print n+0}')" "1" "runs once under the export: the builder grep"
assert_eq "$(xt_norm "$XT_STAMP" | awk 'index($0,"grep -qE -- ")==1 && index($0,"red[- ]?team")>0 {n++} END{print n+0}')" "1" "runs once under the export: the adversarial grep"
assert_eq "$(xt_lines "$XT_STAMP" "grep -owE '[0-9a-f]{7,40}'")" "1" "runs once under the export: the ref scrape"
assert_eq "$(xt_lines "$XT_STAMP" "maude_is_ascii_token $AID")" "1" "runs once under the export: the write-side id guard"
assert_eq "$(xt_lines "$XT_STOP" "maude_is_ascii_token $AID")" "1" "runs once under the export: the clear-side id guard"
assert_eq "$(xt_export_before "$XT_STAMP" ". ")" "1" "…and the export runs before the shared helper is sourced (36th lens, MINOR-8)"
assert_eq "$(xt_export_before "$XT_STOP" ". ")" "1" "…on the clear path too"

# THE PROPERTY, asserted from the environment the guards actually RECEIVED and not from the
# trace (36th lens, IMPORTANT-1: `declare +x LC_ALL` un-exports the locale and every trace
# assertion above stays green; the list above names spellings, and bash has more). A shim for
# the two externals the guards exec, `grep` and `tr`, records the LC_ALL it was handed and
# execs the real binary. It reads the environment, so no spelling of an assignment, an
# un-export or a strip can hide from it, and it is provable on a C-only runner: the caller's
# value is a string the export must override whether or not that locale is installed. What it
# cannot see, named: a dependency on a variable this file does not set (an override knob such
# as `${MAUDE_LC_ALL:-C}`) passes every environment constructed here; no finite pin enumerates
# the environment, and this pin's sentence is about the caller shapes it runs. The shim
# records each call's ARGUMENTS too, and the pin matches each guard once by a fragment of its
# pattern: a guard that bypasses PATH (an absolute path, a function named grep) writes no line
# and is red here, where a floor of one call was green (the 37th lens, IMPORTANT-4 and D2).
# The knob's failure changed shape with the 37th's boundary: the line carries raw bytes
# 0x80-0xff, which a UTF-8 locale cannot collate, so a knob set to en_US.utf8 makes grep
# refuse the pattern ("Invalid collation character", exit 2) and the hook records nothing
# for ANY brief, a missed stamp rather than the false one the 36th replayed
# (replay37a-knob.txt, off-tree). That is the LOUD half. Under C.utf8 grep accepts the
# pattern and decodes UTF-8, so the byte range stops matching a lead byte and every
# non-ASCII bound this file promises (the em dash, the curly quotation mark, a glued
# fullwidth letter) silently stops bounding: five collation pins in this file go red under
# it and nothing is traced (the 38th lens, IMPORTANT-1). The loud failure is the safe one.
# Named, not closed: the guards read grep's exit 2 (a pattern that did not compile) as no
# match, the same as exit 1, and write no trace line for it. The export above the guards
# is what keeps every real run under C.
# Write-through law: the shim dir is created EMPTY by this test, each name is removed before
# it is written, and the real binaries are checked after (the 21st lens wrote a shim through a
# symlink onto /usr/bin/sleep).
test_start "the guards RECEIVE LC_ALL=C whatever the caller exported: a shim on grep and tr records its environment (36th lens, IMPORTANT-1)"
_REAL_GREP="$(command -v grep)"; _REAL_TR="$(command -v tr)"
_LCBIN="$TEST_TMP/lcshim"; _LCLOG="$TEST_TMP/lcshim.log"
rm -rf "$_LCBIN"; mkdir -p "$_LCBIN"; : > "$_LCLOG"
for _b in grep tr; do
  _real="$(command -v "$_b")"; rm -f "$_LCBIN/$_b"
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\t%%s\\n" "%s" "${LC_ALL-<unset>}" "$*" >> "%s"\nexec "%s" "$@"\n' "$_b" "$_LCLOG" "$_real" > "$_LCBIN/$_b"
  chmod +x "$_LCBIN/$_b"
done
assert_ne "$(head -c 2 "$_REAL_GREP")" "#!" "the real grep is still a binary (no write-through)"
assert_ne "$(head -c 2 "$_REAL_TR")" "#!" "the real tr is still a binary (no write-through)"
lc_lines()  { grep -c . "$_LCLOG"; }
lc_c_lines() { awk -F'\t' '$2=="C"' "$_LCLOG" | grep -c .; }
lc_guard()  { awk -F'\t' -v n="$1" -v f="$2" '$1==n && $2=="C" && index($3,f)>0' "$_LCLOG" | grep -c .; }   # $1 name, $2 a fragment of the guard's pattern
# The record proves a CALL bearing each guard's pattern, made through PATH under C, once;
# a guard that greps twice (a decoy through PATH beside a real call by absolute path) buys
# the line, and no finite pin closes a forgery (the 38th lens, MINOR-3).
lc_assert_guards() {   # $1 = the caller shape, for the message
  assert_eq "$(lc_lines)" "$(lc_c_lines)" "[$1] every grep and tr recorded here received LC_ALL=C"
  assert_eq "$(lc_guard grep 'implement ')" "1" "[$1] one call bearing the builder grep's pattern ran through PATH under C"
  assert_eq "$(lc_guard grep 'red[- ]?team')" "1" "[$1] one call bearing the adversarial grep's pattern ran through PATH under C"
  assert_eq "$(lc_guard tr '[:upper:]')" "1" "[$1] one call bearing the lowercasing tr's class ran through PATH under C"
}
_LC_LIST="$LOCALES"; case " $LOCALES " in *" en_US.utf8 "*) ;; *) _LC_LIST="$LOCALES en_US.utf8" ;; esac   # an uninstalled locale is a string the export must override; run it once, not twice
for L in $_LC_LIST; do
  reset_all; : > "$_LCLOG"
  agent_launched "lens" "Attack 7e36d82." "$AID" | env LC_ALL="$L" LC_CTYPE="$L" LC_COLLATE="$L" LANG="$L" LANGUAGE="$L" PATH="$_LCBIN:$PATH" bash "$RT" stamp
  task_stopped "$AID" | env LC_ALL="$L" LC_CTYPE="$L" LC_COLLATE="$L" LANG="$L" LANGUAGE="$L" PATH="$_LCBIN:$PATH" bash "$RT" stamp
  lc_assert_guards "every locale variable=$L"
done
reset_all; : > "$_LCLOG"
agent_launched "lens" "Attack 7e36d82." "$AID" | env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG=en_US.utf8 PATH="$_LCBIN:$PATH" bash "$RT" stamp
lc_assert_guards "LANG only, no LC_ALL"
rm -rf "$_LCBIN"

# MINOR-2 (36th): the commit that shipped the modifier slot said it was "proved against a word
# list"; the list was not on disk. It is here, in the file that ships: the slot's expression is
# read from the hook and every lowercase word but "not" fills it.
test_start "the modifier slot admits any lowercase word but 'not' (the word-except construction, proved on a list, 36th lens, MINOR-2)"
_MOD="$(grep -oE "^_RE_MOD='[^']*'" "$RT" | sed "s/^_RE_MOD='//; s/'\$//")"
assert_ne "$_MOD" "" "the slot's expression is read from the hook"
for _w in a an the careful tdd n no note nothing now none nod nine nota knot; do
  assert_eq "$(printf '%s' "$_w" | LC_ALL=C grep -cE "^${_MOD}\$")" "1" "'$_w' fills the slot"
done
assert_eq "$(printf '%s' "not" | LC_ALL=C grep -cE "^${_MOD}\$")" "0" "'not' does not"

# MINOR-1: the NOTE the CI log is read by was itself unpinned; deleting its block whole left
# the file at 200/0. The line is captured above and asserted here.
test_start "the collation NOTE names its locales on every run (33rd lens, MINOR-1)"
assert_contains "${_NOTE_LOCALES:-}" "collation pins asserted under:" "the NOTE line is printed"
assert_contains "${_NOTE_LOCALES:-}" "$LOCALES" "and it carries the locale set the pins ran under"

print_summary
teardown_test_env
exit $FAILED
