#!/usr/bin/env bash
# Maude mission-hold rail. ONE pin (.mission in care.json), four touches —
# dispatched by subcommand, like maude-run-governor.sh / maude-verify-watch.sh:
#
#   capture  — pin the mission from the only two places it already exists as data:
#              an ExitPlanMode plan, or the active TodoWrite item. Mission-level and
#              STICKY — only these events set/replace it, so the pin stays the
#              through-line, not "the last little thing touched." (PostToolUse.)
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
      TodoWrite|TaskCreate|TaskUpdate)
        # The in-progress item is the current mission; else the first item.
        TEXT="$(printf '%s' "$INPUT" \
          | jq -r '(.tool_input.todos // .tool_input.tasks // []) as $t
                   | (($t | map(select(.status=="in_progress"))) + $t)[0]
                   | (.content // .activeForm // "")' 2>/dev/null \
          | cut -c1-120)"
        ;;
    esac
    [ -n "$TEXT" ] || exit 0
    maude_care_ensure "$CARE"
    maude_care_set "$CARE" --arg t "$TEXT" --arg by "$TOOL" --arg at "$(date +%s)" \
      '.mission = {text:$t, set_by:$by, set_at:($at|tonumber)}'
    maude_log_trace "mission" "captured=$TOOL"
    exit 0
    ;;

  hold)
    [ -f "$CARE" ] || exit 0
    TEXT="$(jq -r '.mission.text // ""' "$CARE" 2>/dev/null)"
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
    [ -f "$CARE" ] && TEXT="$(jq -r '.mission.text // ""' "$CARE" 2>/dev/null)"
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
    maude_care_set "$CARE" 'del(.mission)'
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
