#!/usr/bin/env bash
# Maude care hook — runs on UserPromptSubmit. Tracks session activity and surfaces
# a one-time "you've been at this a while" note past a threshold. Never blocks.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Care state lives in her closet. Auto-create — it's her own dir.
maude_ensure_self_dir
SELF="$(maude_self_dir)"
CARE="$SELF/care.json"
NOW="$(date +%s)"
TODAY="$(date +%Y-%m-%d)"

# Read existing state (if jq available)
PREV_DATE=""
SESSION_START=""
PROMPTS=0
LONG_FLAG_FIRED=""

if [ -f "$CARE" ] && command -v jq >/dev/null 2>&1; then
  PREV_DATE="$(jq -r '.last_date // ""' "$CARE" 2>/dev/null)"
  SESSION_START="$(jq -r '.session_start // ""' "$CARE" 2>/dev/null)"
  PROMPTS="$(jq -r '.prompts_this_session // 0' "$CARE" 2>/dev/null)"
  LONG_FLAG_FIRED="$(jq -r '.long_flag_fired // ""' "$CARE" 2>/dev/null)"
fi

# Roll over to a new session if it's a new day or we haven't tracked one
if [ "$PREV_DATE" != "$TODAY" ] || [ -z "$SESSION_START" ]; then
  SESSION_START="$NOW"
  PROMPTS=0
  LONG_FLAG_FIRED=""
fi

PROMPTS=$((PROMPTS + 1))

# Compute hours active
HOURS=$(( (NOW - SESSION_START) / 3600 ))

# If session > 4 hours and we haven't fired the flag yet, surface a gentle note
if [ "$HOURS" -ge 4 ] && [ -z "$LONG_FLAG_FIRED" ]; then
  printf 'Maude: you have been at this %d hours. Save soon, eat something.\n' "$HOURS" >&2
  LONG_FLAG_FIRED="$TODAY"
fi

# Write back state. care.json is the WHOLE plugin's shared state file — probe-tier1
# (tier1_*), clear-gate/conscience (gate_cleared; the gate hook only reads+consumes
# it), drift-watch (drift_warned), and pre-tool-use (claudemd_warned) all keep keys
# here. care runs every UserPromptSubmit,
# so it must MERGE its 5 fields, never rewrite the file from scratch (that wiped
# everyone else's state every prompt). Mirror probe-tier1.sh's jq-merge + atomic mv.
if command -v jq >/dev/null 2>&1; then
  # Ensure a valid base object so the merge works on first run, an EMPTY file, OR a
  # corrupt NON-EMPTY one — without this an invalid care.json would make every merge
  # fail and freeze care/probe/drift/gate state forever (silently, with jq present).
  # On a corrupt file the transient shared state is reset; maude_care_ensure now
  # RECORDS that in the trace (it used to be a silent wipe — the R2 finding).
  maude_care_ensure "$CARE"
  maude_care_set "$CARE" --arg ld "$TODAY" --arg la "$NOW" --arg ss "$SESSION_START" \
     --arg p "$PROMPTS" --arg lf "$LONG_FLAG_FIRED" \
     '. + {last_date: $ld, last_active: ($la|tonumber), session_start: ($ss|tonumber), prompts_this_session: ($p|tonumber), long_flag_fired: $lf}'
else
  # No jq — leave care.json UNTOUCHED. Without a JSON parser, care can neither read
  # its own fields (the read block above is jq-gated, so the long-session nudge can
  # never fire) nor merge — and a scratch rewrite would CLOBBER every foreign key
  # that other hooks keep here (tier1_*, gate_cleared, drift_warned, claudemd_warned)
  # on every prompt. care is simply inert without jq (the SessionStart notice already
  # tells the user the hooks are degraded); it must not destroy shared state to be so.
  :
fi

exit 0
