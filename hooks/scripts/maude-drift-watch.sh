#!/usr/bin/env bash
# Maude drift-watch hook — runs on UserPromptSubmit. Reads today's trace and
# whispers when Claude is repeating himself: same file Read N+ times, or Grep
# hammered N+ times in the recent window.
#
# Whispers via stderr — Claude reads as additional context, user sees as
# system note. Always exits 0.
#
# Cooldown: care.json `.drift_warned.<key>` stamped with today's date — once
# per signal per day. Resets next day automatically.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

TRACE="$(maude_self_dir)/trace/today-$(date +%Y-%m-%d).jsonl"
[ -f "$TRACE" ] || exit 0

CARE="$(maude_self_dir)/care.json"
TODAY="$(date +%Y-%m-%d)"

# Pull last 30 tool events
TAIL="$(tail -30 "$TRACE" | jq -c 'select(.kind == "tool")' 2>/dev/null)"
[ -z "$TAIL" ] && exit 0

# --- Signal 1: Grep hammering (≥4 in last 30 events) ---
GREP_COUNT=$(printf '%s\n' "$TAIL" | jq -r 'select(.tool == "Grep") | .ts' 2>/dev/null | wc -l)
if [ "$GREP_COUNT" -ge 4 ]; then
  WARNED=""
  [ -f "$CARE" ] && WARNED="$(jq -r '.drift_warned.grep // ""' "$CARE" 2>/dev/null)"
  if [ "$WARNED" != "$TODAY" ]; then
    printf 'Maude: noticed Claude grepping %d times in the last 30 tool calls. He may be stuck on something — worth a sanity check.\n' "$GREP_COUNT" >&2
    if [ -f "$CARE" ]; then
      TMP="$(mktemp 2>/dev/null)" && jq --arg t "$TODAY" '.drift_warned.grep = $t' "$CARE" > "$TMP" 2>/dev/null && mv "$TMP" "$CARE"
    fi
    maude_log_trace "drift" "kind=grep count=$GREP_COUNT"
  fi
fi

# --- Signal 2: Same Read target ≥3 times today ---
DUP="$(printf '%s\n' "$TAIL" | jq -r 'select(.tool == "Read" and .target != null) | .target' 2>/dev/null | sort | uniq -c | awk '$1 >= 3 {print}' | sort -rn | head -1)"
if [ -n "$DUP" ]; then
  COUNT="$(printf '%s' "$DUP" | awk '{print $1}')"
  TARGET="$(printf '%s' "$DUP" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
  WARNED=""
  [ -f "$CARE" ] && WARNED="$(jq -r --arg t "$TARGET" '.drift_warned.read_targets[$t] // ""' "$CARE" 2>/dev/null)"
  if [ "$WARNED" != "$TODAY" ]; then
    BASE="$(basename "$TARGET")"
    printf 'Maude: noticed Claude has Read %s %d times today. Worth checking what he is looking for.\n' "$BASE" "$COUNT" >&2
    if [ -f "$CARE" ]; then
      TMP="$(mktemp 2>/dev/null)" && jq --arg t "$TARGET" --arg today "$TODAY" '.drift_warned.read_targets[$t] = $today' "$CARE" > "$TMP" 2>/dev/null && mv "$TMP" "$CARE"
    fi
    maude_log_trace "drift" "kind=read target=$BASE count=$COUNT"
  fi
fi

exit 0
