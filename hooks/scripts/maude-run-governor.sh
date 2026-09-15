#!/usr/bin/env bash
# Maude run-governor — the "jacket". Bounds how long Claude runs UNATTENDED:
# counts tool-actions + wall-clock since the last human turn, whispers a soft
# checkpoint past a threshold, and HARD-PAUSES (exit 2) past a ceiling until a
# human turn (UserPromptSubmit → reset) or /maude:conscience run-governor.
#
# Modes (dispatched by $1, mirroring maude-trace.sh / maude-verify-watch.sh):
#   reset (UserPromptSubmit) — human spoke: zero actions, stamp last_human_ts, clear soft flag.
#   tick  (PostToolUse, all tools) — increment actions_since_human; init last_human_ts if unset.
#   gate  (PreToolUse, all tools) — soft-surface once past threshold; hard-pause past ceiling.
#
# State: care.json `.run_state` = {actions_since_human, last_human_ts, soft_warned} for the
# main thread; `.run_agents[<agent_id>]` = the same shape, one per subagent. Inside a
# subagent the harness stamps `agent_id` on every tool hook's stdin (the main thread
# carries none, and only the main thread ever gets a UserPromptSubmit), so each agent is
# governed on ITS OWN count and clock: a fleet no longer pools its calls into one ceiling
# and blocks every worker together. A human turn resets the main counter and drops every
# agent slot (they belonged to the turn that just ended; a background agent still running
# across that turn is forgiven with them, as every agent was before), and a subagent's
# stop drops its own slot (maude-subagent-stop.sh), so the map never outgrows the fleet.
# Thresholds (env-overridable): MAUDE_RUN_SOFT_ACTIONS/MINS, MAUDE_RUN_HARD_ACTIONS/MINS.
# ADVISORY layer (a checkpoint, NOT irreversible-action protection) → fail-OPEN
# without jq. Always exits 0 except a gate-mode hard-pause (exit 2).
#
# Off-switch:
#   MAUDE_RUN_GOVERNOR=off (also 0/false/no) — disables the governor entirely
#   (all modes exit 0). Set in settings.json `env` for a deployment/session that
#   should never be gated (e.g. a cron worker). Default: ON.
#
# Window stand-down (overnight runs):
#   A live /maude:conscience run-governor token (care.json
#   `.gate_cleared["run-governor"].until`) suppresses both the soft whisper and
#   the hard ceiling for the duration of its window. The token is NOT consumed —
#   it rides until `until` expires, then normal governing resumes. A human turn
#   (reset) does NOT clear the token — the overnight window the user set intentionally
#   keeps running. Only token expiry re-arms the governor. Example:
#   `/maude:conscience run-governor 36000` stands the governor down for 10 hours.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0   # advisory: inert without jq

# Off-switch: a deployment/session can disable the governor entirely (e.g. an
# intentional overnight run). Default is ON.
case "${MAUDE_RUN_GOVERNOR:-on}" in
  off|OFF|0|false|no|NO) exit 0 ;;
esac

MODE="${1:-}"
NOW="$(date +%s)"
SOFT_A="${MAUDE_RUN_SOFT_ACTIONS:-40}"
SOFT_M="${MAUDE_RUN_SOFT_MINS:-40}"
HARD_A="${MAUDE_RUN_HARD_ACTIONS:-80}"
HARD_M="${MAUDE_RUN_HARD_MINS:-90}"

maude_ensure_self_dir
CARE="$(maude_self_dir)/care.json"
maude_care_ensure "$CARE"

# Read the envelope once, only for the modes that carry one (tick and gate): reset has
# nothing to read, and a hand-run from a tty must not sit on cat.
INPUT=""
case "$MODE" in tick|gate) [ -t 0 ] || INPUT="$(cat 2>/dev/null)" ;; esac
AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)"
# The jq path of the counter this call governs.
if [ -n "$AID" ]; then RS='.run_agents[$aid]'; else RS='.run_state'; fi

case "$MODE" in
  reset)
    maude_care_set "$CARE" --argjson now "$NOW" \
      '.run_state = ((.run_state // {}) + {actions_since_human: 0, last_human_ts: $now, soft_warned: false}) | .run_agents = {}'
    ;;
  tick)
    maude_care_set "$CARE" --arg aid "$AID" --argjson now "$NOW" \
      "$RS = (($RS // {}) | .actions_since_human = ((.actions_since_human // 0) + 1) | .last_human_ts = (.last_human_ts // \$now))"
    ;;
  gate)
    # The escape hatch must ALWAYS be reachable, or the ceiling deadlocks: never
    # gate the conscience-clear command itself.
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
    case "$CMD" in *maude-clear-gate.sh*) exit 0 ;; esac

    # Window stand-down: a LIVE /maude:conscience run-governor token suppresses the
    # governor for its whole window (overnight runs). NOT consumed — it rides until
    # `until` expires, then normal governing resumes. (A human turn always resets.)
    CU="$(jq -r '.gate_cleared["run-governor"].until // 0' "$CARE" 2>/dev/null)"
    if [ -n "$CU" ] && [ "$CU" -gt 0 ] && [ "$CU" -gt "$NOW" ] 2>/dev/null; then
      maude_log_trace "run-governor" "stood-down until=$CU"
      exit 0
    fi

    ACTIONS="$(jq -r --arg aid "$AID" "$RS.actions_since_human // 0" "$CARE" 2>/dev/null)"
    LAST_HUMAN="$(jq -r --arg aid "$AID" "$RS.last_human_ts // 0" "$CARE" 2>/dev/null)"
    SOFT_WARNED="$(jq -r --arg aid "$AID" "$RS.soft_warned // false" "$CARE" 2>/dev/null)"
    [ "$LAST_HUMAN" -gt 0 ] 2>/dev/null || LAST_HUMAN="$NOW"
    ELAPSED_MIN=$(( (NOW - LAST_HUMAN) / 60 ))
    # A subagent has no human to turn to: its clock runs from its dispatch, and the
    # only move it can make at the ceiling is to finish and hand back what it has.
    if [ -n "$AID" ]; then
      WHO="agent ${AID:0:8}: "; CLOCK="since it was dispatched"
      HARD_MOVE="finish and report what you have to the agent that dispatched you; the human can widen the budget with /maude:conscience run-governor"
    else
      WHO=""; CLOCK="since the last human turn"
      HARD_MOVE="Take a turn with your human, or run /maude:conscience run-governor to continue with a fresh budget"
    fi

    # Hard ceiling — actions OR minutes.
    if [ "$ACTIONS" -ge "$HARD_A" ] 2>/dev/null || [ "$ELAPSED_MIN" -ge "$HARD_M" ] 2>/dev/null; then
      maude_log_trace "run-governor" "blocked actions=$ACTIONS elapsed_min=$ELAPSED_MIN${AID:+ agent=${AID:0:8}}"
      printf 'Maude: run-governor — %s%s tool actions / %s min %s. Hard checkpoint: this run has gone unattended a long time. %s.\n' "$WHO" "$ACTIONS" "$ELAPSED_MIN" "$CLOCK" "$HARD_MOVE" >&2
      # NAME THE FILE WE LOOKED IN — this is the second reader of the yellow token
      # (after maude-gate.sh), and its writer maude-clear-gate.sh names where it
      # wrote. Same split shape as the 2026-09-02 bug: hook reads, Bash-tool
      # script infers. Without this line the two could disagree in silence.
      printf '       (looked in: %s)\n' "$CARE" >&2
      exit 2
    fi

    # Soft threshold — whisper once per budget.
    if { [ "$ACTIONS" -ge "$SOFT_A" ] 2>/dev/null || [ "$ELAPSED_MIN" -ge "$SOFT_M" ] 2>/dev/null; } && [ "$SOFT_WARNED" != "true" ]; then
      printf 'Maude: run-governor — %s%s tool actions / %s min %s. Worth a checkpoint: summarize where you are and what RED line is next. (Hard pause at %s tool actions / %s min.)\n' "$WHO" "$ACTIONS" "$ELAPSED_MIN" "$CLOCK" "$HARD_A" "$HARD_M" >&2
      maude_care_set "$CARE" --arg aid "$AID" "$RS.soft_warned = true"
      maude_log_trace "run-governor" "soft-warn actions=$ACTIONS elapsed_min=$ELAPSED_MIN${AID:+ agent=${AID:0:8}}"
    fi
    ;;
  *)
    exit 0 ;;
esac
exit 0
