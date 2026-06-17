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
# State: care.json `.run_state` = {actions_since_human, last_human_ts, soft_warned}.
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

case "$MODE" in
  reset)
    maude_care_set "$CARE" --argjson now "$NOW" \
      '.run_state = ((.run_state // {}) + {actions_since_human: 0, last_human_ts: $now, soft_warned: false})'
    ;;
  tick)
    maude_care_set "$CARE" --argjson now "$NOW" \
      '.run_state = ((.run_state // {}) | .actions_since_human = ((.actions_since_human // 0) + 1) | .last_human_ts = (.last_human_ts // $now))'
    ;;
  gate)
    INPUT="$(cat 2>/dev/null)"
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

    ACTIONS="$(jq -r '.run_state.actions_since_human // 0' "$CARE" 2>/dev/null)"
    LAST_HUMAN="$(jq -r '.run_state.last_human_ts // 0' "$CARE" 2>/dev/null)"
    SOFT_WARNED="$(jq -r '.run_state.soft_warned // false' "$CARE" 2>/dev/null)"
    [ "$LAST_HUMAN" -gt 0 ] 2>/dev/null || LAST_HUMAN="$NOW"
    ELAPSED_MIN=$(( (NOW - LAST_HUMAN) / 60 ))

    # Hard ceiling — actions OR minutes.
    if [ "$ACTIONS" -ge "$HARD_A" ] 2>/dev/null || [ "$ELAPSED_MIN" -ge "$HARD_M" ] 2>/dev/null; then
      maude_log_trace "run-governor" "blocked actions=$ACTIONS elapsed_min=$ELAPSED_MIN"
      printf 'Maude: run-governor — %s tool-actions / %s min since John last spoke. Hard checkpoint: you have run unattended a long time. Take a turn with John, or run /maude:conscience run-governor to continue with a fresh budget.\n' "$ACTIONS" "$ELAPSED_MIN" >&2
      exit 2
    fi

    # Soft threshold — whisper once per budget.
    if { [ "$ACTIONS" -ge "$SOFT_A" ] 2>/dev/null || [ "$ELAPSED_MIN" -ge "$SOFT_M" ] 2>/dev/null; } && [ "$SOFT_WARNED" != "true" ]; then
      printf 'Maude: run-governor — %s actions / %s min since a human turn. Worth a checkpoint: summarize where you are and what RED line is next. (Hard pause at %s actions / %s min.)\n' "$ACTIONS" "$ELAPSED_MIN" "$HARD_A" "$HARD_M" >&2
      maude_care_set "$CARE" '.run_state.soft_warned = true'
      maude_log_trace "run-governor" "soft-warn actions=$ACTIONS elapsed_min=$ELAPSED_MIN"
    fi
    ;;
  *)
    exit 0 ;;
esac
exit 0
