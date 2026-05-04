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

# Write back state — minimal JSON, no jq needed for output
{
  printf '{\n'
  printf '  "last_date": "%s",\n' "$TODAY"
  printf '  "last_active": %s,\n' "$NOW"
  printf '  "session_start": %s,\n' "$SESSION_START"
  printf '  "prompts_this_session": %d,\n' "$PROMPTS"
  printf '  "long_flag_fired": "%s"\n' "$LONG_FLAG_FIRED"
  printf '}\n'
} > "$CARE"

exit 0
