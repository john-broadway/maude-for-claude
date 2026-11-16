#!/usr/bin/env bash
# Maude's Rolodex cue (UserPromptSubmit): when the person's prompt carries a phrase from
# a trade the user approved, she says the one approved line naming who handles it.
#
# Quiet on any doubt: no jq, no python3, no prompt, a machine turn or another agent's
# words, no session id, no Rolodex store. Once per session per trade (a seen file per
# session under the home dir); the next-best trade never steps in. The words come
# from the approved page, re-hashed and validated in maude_rolodex, never from an index.
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$(maude_rolodex_dir)/rolodex.db" ] || exit 0

INPUT="$(cat 2>/dev/null)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .message // ""' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0
maude_prompt_is_machine "$PROMPT" && exit 0
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | cut -c1-64)"
[ -n "$SID" ] || exit 0

# Under the user's home, one dir per project: the project closet is a cloned repo's ground,
# and a planted link there would send the seen file and the sweep anywhere.
SEEN_DIR="$(maude_user_dir)/rolodex-seen/$(printf '%s' "$(maude_project_dir)" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$SEEN_DIR" 2>/dev/null || exit 0

OUT="$(printf '%s' "$PROMPT" | maude_timeout 4 python3 -I -c "$MAUDE_PY_BOOT" \
  "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_rolodex cue \
  --home "$HOME" --project "$(maude_project_dir)" --seen "$SEEN_DIR/$SID" 2>/dev/null)"
find "$SEEN_DIR" -maxdepth 1 -type f -mtime +7 ! -name "$SID" -delete 2>/dev/null

LINE="${OUT%%$'\n'*}"
META="${OUT#*$'\n'}"
case "$LINE" in "**Maude:** I know who handles that: "*) ;; *) exit 0 ;; esac
[ "$META" != "$OUT" ] || exit 0

printf '%s\n' "$LINE"
maude_log_spend "rolodex-cue" "$(printf '%s\n' "$LINE" | wc -c | tr -d ' ')"

SLUG="${META%%$'\t'*}"; REST="${META#*$'\t'}"
KIND="${REST%%$'\t'*}"; NAME="${REST#*$'\t'}"
TRACE="$(maude_trace_file)"
mkdir -p "$(dirname "$TRACE")" 2>/dev/null
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "trade=$SLUG pick=$KIND:$NAME" \
  --arg s "$(maude_session_label "$SID")" --arg sid "$(printf '%.8s' "$SID")" \
  '{ts:$ts, kind:"rolodex", payload:$p, session:$s, sid:$sid}' >> "$TRACE" 2>/dev/null
exit 0
