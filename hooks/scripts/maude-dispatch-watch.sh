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

# Only Agent/Task dispatches (the matcher scopes this, but self-guard anyway).
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
case "$TOOL" in
  Agent|Task) ;;
  *) exit 0 ;;
esac

MODEL="$(printf '%s' "$INPUT" | jq -r '.tool_input.model // ""' 2>/dev/null)"

# Right-sized tiers pass silently. Anything else — a flagship tier by name, or
# no model at all — is the drift. Tier names, not deployment specifics: these
# are the public Anthropic model tiers.
case "$MODEL" in
  haiku|sonnet) exit 0 ;;
esac

CARE="$(maude_self_dir)/care.json"
TODAY="$(date +%Y-%m-%d)"
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
