#!/usr/bin/env bash
# Maude mission-hold rail. One pin PER SESSION (.missions[<session_id>] in care.json),
# four touches —
# dispatched by subcommand, like maude-run-governor.sh / maude-verify-watch.sh:
#
#   capture  — pin the mission from the only places it already exists as data:
#              an ExitPlanMode plan, the task flipped to in_progress (TaskCreate +
#              TaskUpdate), or a TodoWrite list where a harness emits one.
#              Mission-level and STICKY — creating a task does NOT move the pin, so
#              it stays the through-line, not "the last little thing touched."
#              (PostToolUse.)
#   hold     — inject `MISSION: <x>` on every prompt. The anti-fade: a re-injected
#              line can't scroll out of view the way a session-start statement does.
#              (UserPromptSubmit.)
#   verify   — at the action-flip (the first Write/Edit/Bash after a talking stretch,
#              read from the trace), whisper the pinned mission: still this, or did you
#              wander? No pin → ask what you're doing. (PreToolUse Write|Edit|Bash.)
#   clear    — wipe the pin. (SessionStart only — NOT Stop, which fires every turn and
#              would erase the pin mid-session.)
#
# Whispers go to stderr (Claude reads as context, user sees as a system note).
# ALWAYS exits 0 — a rail that holds the mission must never block the work.
#
# Honest seam: detecting the flip is deterministic (the trace); auto-capturing the
# mission TEXT only works from the plan/todo payloads a hook can read — the verify
# fallback forces a declaration otherwise. The "am I drifting" judgment is Claude's;
# this supplies the timing and the pinned mission at the moment of the flip.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

SUB="${1:-}"

# jq is required to read/parse tool input and merge care.json. Without it the rail
# is inert (consistent with the rest of the plugin's soft-jq dependency).
command -v jq >/dev/null 2>&1 || exit 0

CARE="$(maude_self_dir)/care.json"
INPUT="$(cat 2>/dev/null)"

# THE PIN IS PER SESSION. care.json is ONE file shared by every session at a project
# root, so an unscoped `.mission` let a sibling session read this one's mission — three
# misfires in the hour after the rail first went live on 2026-07-30, including a
# proximo lane being told to "design UNDO pillar, get approval first". A rail that
# cries wolf is one you learn to skim, which costs you the times it is right.
# Task IDs restart per session too, so the id->subject map is scoped the same way:
# unscoped, session B's task #5 silently overwrote session A's.
# "default" keeps single-session behaviour (and harnesses that send no id) unchanged.
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$SID" ] || SID="default"

# Action tools — the ones whose first appearance after a prompt marks the flip
# from thinking to doing.
ACTION_RE='^(Write|Edit|MultiEdit|Bash)$'

case "$SUB" in
  capture)
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
    TEXT=""
    case "$TOOL" in
      ExitPlanMode)
        # First non-blank line of the plan, stripped of markdown heading/bullet
        # markers, trimmed, capped — the plan's headline is the mission.
        PLAN="$(printf '%s' "$INPUT" | jq -r '.tool_input.plan // ""' 2>/dev/null)"
        TEXT="$(printf '%s\n' "$PLAN" \
          | sed -E 's/^[[:space:]]*#+[[:space:]]*//; s/^[[:space:]]*[-*][[:space:]]*//' \
          | grep -m1 '[^[:space:]]' \
          | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
          | cut -c1-120)"
        ;;
      TodoWrite)
        # The in-progress item is the current mission; else the first item.
        TEXT="$(printf '%s' "$INPUT" \
          | jq -r '(.tool_input.todos // .tool_input.tasks // []) as $t
                   | (($t | map(select(.status=="in_progress"))) + $t)[0]
                   | (.content // .activeForm // "")' 2>/dev/null \
          | cut -c1-120)"
        ;;
      TaskCreate)
        # This harness does NOT emit TodoWrite. Measured 2026-07-30 over 25 real
        # transcripts: TodoWrite 0, TaskCreate 21, TaskUpdate 28. TaskCreate sends a
        # FLAT object {subject, description, activeForm} — no array, no status — so
        # the TodoWrite parse above resolved to [] and the rail sat inert from the
        # day it was built.
        #
        # Creating a task is not working on it, so a TaskCreate does NOT steal an
        # existing pin: the pin is the through-line, not the last thing touched.
        # It does two things: record id -> subject so TaskUpdate can resolve text it
        # never carries, and pin only when nothing is pinned yet (parity with
        # TodoWrite's "in-progress item, ELSE the first item").
        # The id lives only in the RESPONSE, as structured data:
        #   tool_response = {task: {id: "2", subject: "…"}}
        # NOT as the "Task #N created successfully: …" sentence — that is the
        # RENDERED tool_result you see in a transcript, and building against it
        # produced a rail that passed its tests and wrote no map on the live box.
        # Prefer the response's subject: it is what the task system actually
        # recorded, not what we asked it to record.
        SUBJ="$(printf '%s' "$INPUT" \
          | jq -r '.tool_response.task.subject // .tool_input.subject
                   // .tool_input.activeForm // ""' 2>/dev/null \
          | cut -c1-120)"
        TID="$(printf '%s' "$INPUT" \
          | jq -r '(.tool_response.task.id // .tool_response.taskId // "") | tostring' 2>/dev/null)"
        if [ -n "$SUBJ" ] && [ -n "$TID" ]; then
          maude_care_ensure "$CARE"
          maude_care_set "$CARE" --arg i "$TID" --arg s "$SUBJ" --arg sid "$SID" \
            '.mission_tasks = ((.mission_tasks // {}) |
               .[$sid] = (((.[$sid]) // {}) + {($i): $s}))'
        fi
        # Pin only if THIS session has nothing pinned.
        if [ -z "$(jq -r --arg sid "$SID" '.missions[$sid].text // ""' "$CARE" 2>/dev/null)" ]; then
          TEXT="$SUBJ"
        fi
        ;;
      TaskUpdate)
        # {taskId, status} and no text at all — the subject is resolved from the map
        # TaskCreate wrote. Flipping a task to in_progress is the direct analogue of
        # TodoWrite's select(.status=="in_progress"), so it REPLACES the pin.
        # Any other status (completed / pending) leaves the pin alone: finishing a
        # step must not blank the mission mid-thread.
        ST="$(printf '%s' "$INPUT" | jq -r '.tool_input.status // ""' 2>/dev/null)"
        [ "$ST" = "in_progress" ] || exit 0
        TID="$(printf '%s' "$INPUT" | jq -r '.tool_input.taskId // ""' 2>/dev/null)"
        # Unknown id -> "" -> the common guard below exits without touching the pin.
        [ -n "$TID" ] && TEXT="$(jq -r --arg i "$TID" --arg sid "$SID" \
          '.mission_tasks[$sid][$i] // ""' "$CARE" 2>/dev/null | cut -c1-120)"
        ;;
    esac
    [ -n "$TEXT" ] || exit 0
    maude_care_ensure "$CARE"
    maude_care_set "$CARE" --arg t "$TEXT" --arg by "$TOOL" --arg at "$(date +%s)" --arg sid "$SID" \
      '.missions = ((.missions // {}) | .[$sid] = {text:$t, set_by:$by, set_at:($at|tonumber)})'
    maude_log_trace "mission" "captured=$TOOL"
    exit 0
    ;;

  hold)
    [ -f "$CARE" ] || exit 0
    TEXT="$(jq -r --arg sid "$SID" '.missions[$sid].text // ""' "$CARE" 2>/dev/null)"
    if [ -n "$TEXT" ]; then
      printf 'MISSION: %s\n' "$TEXT" >&2
      # #49: re-injected every prompt — the definition of a bill worth watching.
      maude_log_spend "mission-hold" "$(printf 'MISSION: %s' "$TEXT" | wc -c | tr -d ' ')"
    fi
    exit 0
    ;;

  verify)
    # Flip = no action-tool event in the trace since the last prompt. (PreToolUse
    # runs BEFORE this call is traced, so the trace holds only prior events.)
    TRACE="$(maude_trace_file)"
    PRIOR_ACTIONS=0
    if [ -f "$TRACE" ]; then
      PRIOR_ACTIONS="$(jq -s '
        . as $ev
        | (reduce range(0; ($ev|length)) as $i (-1; if $ev[$i].kind=="prompt" then $i else . end)) as $lp
        | [ $ev[($lp+1):][] | select(.kind=="tool" and ((.tool // "") | test("'"$ACTION_RE"'"))) ]
        | length' "$TRACE" 2>/dev/null)"
      [ -n "$PRIOR_ACTIONS" ] || PRIOR_ACTIONS=0
    fi
    # Mid-streak — already acting this turn. Stay quiet.
    [ "$PRIOR_ACTIONS" -gt 0 ] 2>/dev/null && exit 0

    TEXT=""
    [ -f "$CARE" ] && TEXT="$(jq -r --arg sid "$SID" '.missions[$sid].text // ""' "$CARE" 2>/dev/null)"
    if [ -n "$TEXT" ]; then
      printf 'MISSION: %s — about to act. Still this, or did you wander?\n' "$TEXT" >&2
    else
      printf 'No mission pinned — what are you doing, and is it where this thread started?\n' >&2
    fi
    exit 0
    ;;

  clear)
    [ -f "$CARE" ] || exit 0
    maude_care_ensure "$CARE"
    # The task map goes too. Task numbers restart per session, so a map left behind
    # would let a fresh "#1" resolve to LAST session's subject and pin a mission
    # nobody set — worse than no pin, because it reads as authoritative.
    maude_care_set "$CARE" --arg sid "$SID" \
      'del(.missions[$sid]) | del(.mission_tasks[$sid])'
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
