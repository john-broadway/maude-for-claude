#!/usr/bin/env bash
# Maude dispatch-watch hook — fires before Agent/Task sub-agent dispatches.
# Spots the model-to-task mismatch: sub-work (scouts, searches, mechanical
# edits) dispatched on a flagship-tier model, or with no model at all — which
# silently inherits whatever the main loop runs on, usually the flagship.
# That's the documented drift: big-model tokens spent on small-model work.
#
# Whispers via stderr — never blocks (a wrong-sized dispatch is wasteful, not
# dangerous). Always exits 0.
#
# Cooldown: care.json `.dispatch_warned` stamped with today's date — once per
# day, one shared key (flagship and unset are the same drift class: "the model
# wasn't matched to the task"). Resets next day automatically.
#
# jq-absent → inert, like every other counting hook.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

# Only Agent/Task/Workflow dispatches (the matcher scopes this, but self-guard anyway).
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
case "$TOOL" in
  Agent|Task|Workflow) ;;
  *) exit 0 ;;
esac

CARE="$(maude_self_dir)/care.json"
TODAY="$(date +%Y-%m-%d)"

# ── Workflow: the drift's second home ─────────────────────────────────────
# A workflow script's agent() calls never pass through the Agent tool, so the
# whisper below can't see them — and stock/named harnesses set no model: at
# all, so EVERY agent() inherits the flagship main loop. Separate daily
# cooldown key: an Agent-side whisper must not silence this one (the workflow
# case is the one that recurs).
if [ "$TOOL" = "Workflow" ]; then
  maude_care_ensure "$CARE"
  WARNED="$(jq -r '.dispatch_warned_workflow // ""' "$CARE" 2>/dev/null)"
  [ "$WARNED" = "$TODAY" ] && exit 0

  SCRIPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.script // ""' 2>/dev/null)"
  if [ -z "$SCRIPT" ]; then
    SPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.scriptPath // ""' 2>/dev/null)"
    [ -n "$SPATH" ] && [ -r "$SPATH" ] && SCRIPT="$(cat "$SPATH" 2>/dev/null)"
  fi

  if [ -n "$SCRIPT" ]; then
    # Inspectable script: agent() calls with no model: anywhere = the drift.
    printf '%s' "$SCRIPT" | grep -q 'agent(' || exit 0
    printf '%s' "$SCRIPT" | grep -q 'model:' && exit 0
    printf 'Maude: this workflow'\''s agent() calls set no model: — every one inherits the main loop (usually the flagship). Add model: per stage before the burn (verify → haiku, review/search → sonnet).\n' >&2
  else
    # Named workflow: the script is registry-resolved, not inspectable here.
    NAME="$(printf '%s' "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null)"
    [ -n "$NAME" ] || exit 0
    printf 'Maude: named workflow "%s" — stock harnesses set no model: and default every agent() to the flagship. Grab the persisted scriptPath from the tool result, grep it for model:, and tier the stages before the expensive phase runs.\n' "$NAME" >&2
  fi
  maude_care_set "$CARE" --arg t "$TODAY" '.dispatch_warned_workflow = $t'
  maude_log_trace "drift" "kind=dispatch-workflow"
  exit 0
fi

MODEL="$(printf '%s' "$INPUT" | jq -r '.tool_input.model // ""' 2>/dev/null)"

# Right-sized tiers pass silently. Anything else — a flagship tier by name, or
# no model at all — is the drift. Tier names, not deployment specifics: these
# are the public Anthropic model tiers.
case "$MODEL" in
  haiku|sonnet) exit 0 ;;
esac

maude_care_ensure "$CARE"

WARNED="$(jq -r '.dispatch_warned // ""' "$CARE" 2>/dev/null)"
[ "$WARNED" = "$TODAY" ] && exit 0

if [ -n "$MODEL" ]; then
  printf 'Maude: this sub-agent is dispatching on "%s" (a flagship tier). Match the model to the sub-task — scouts and searches run fine on haiku, build/review on sonnet.\n' "$MODEL" >&2
else
  printf 'Maude: this sub-agent has no model set — it inherits the main loop (usually the flagship). Match the model to the sub-task: scouts/searches → haiku, build/review → sonnet.\n' >&2
fi

maude_care_set "$CARE" --arg t "$TODAY" '.dispatch_warned = $t'
maude_log_trace "drift" "kind=dispatch model=${MODEL:-unset}"

exit 0
