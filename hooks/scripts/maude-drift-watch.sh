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

TRACE="$(maude_trace_file)"
[ -f "$TRACE" ] || exit 0

CARE="$(maude_self_dir)/care.json"
TODAY="$(date +%Y-%m-%d)"

# Ensure care.json is a valid JSON object before jq tries to merge into it. The
# shared helper seeds {} when missing/empty AND heals (with a trace) a corrupt
# non-empty file — without that, a corrupt care.json froze the cooldown write below
# (the merge silently failed, so the whisper could never remember it fired).
maude_care_ensure "$CARE"

# The session tie (the fleet fix): several concurrent sessions share this trace,
# and "Claude is stuck" must be about THIS session's Claude, not a neighbor's.
# Scope the window to the current session's events; unlabeled (pre-upgrade)
# entries never count. Cooldowns nest per-session too — a whisper to one
# session must not mute a genuine one in another. The envelope's session_id
# goes into the SAME label computation the trace writer used, so the filter
# below matches what was actually stamped.
SID="$(jq -r '.session_id // ""' 2>/dev/null)"
SLBL="$(maude_session_label "$SID")"

# Pull last 30 of THIS session's tool events. The raw slice is wider because
# interleaved neighbors dilute the file — 30 raw lines may hold few of ours.
TAIL="$(tail -200 "$TRACE" | jq -c --arg s "$SLBL" 'select(.kind == "tool" and .session == $s)' 2>/dev/null | tail -30)"
[ -z "$TAIL" ] && exit 0

# Legacy-schema heal, folded into whichever write fires first: drift_warned used
# to hold a flat `.grep` (string) / `.read_targets` (object of date-strings);
# per-session state nests under a session-label key instead. Drop the flat
# leftovers so the shapes never mix. (Worst case if a session is literally
# named "read_targets" and trips the type-guard: one duplicate whisper.)
HEAL='(if ((.drift_warned.grep? // null)|type) == "string" then del(.drift_warned.grep) else . end)
  | (if ((.drift_warned.read_targets? // null)|type) == "object"
        and ((.drift_warned.read_targets // {}) | [.[]] | length > 0)
        and ((.drift_warned.read_targets // {}) | [.[]] | all(type == "string"))
     then del(.drift_warned.read_targets) else . end)'

# --- Signal 1: Grep hammering (≥4 in this session's last 30 events) ---
GREP_COUNT=$(printf '%s\n' "$TAIL" | jq -r 'select(.tool == "Grep") | .ts' 2>/dev/null | wc -l)
if [ "$GREP_COUNT" -ge 4 ]; then
  # care.json is guaranteed present + valid by maude_care_ensure above, so no -f guard.
  WARNED="$(jq -r --arg s "$SLBL" '.drift_warned[$s].grep // ""' "$CARE" 2>/dev/null)"
  if [ "$WARNED" != "$TODAY" ]; then
    printf 'Maude: noticed Claude grepping %d times in the last 30 tool calls. He may be stuck on something — worth a sanity check.\n' "$GREP_COUNT" >&2
    maude_care_set "$CARE" --arg t "$TODAY" --arg s "$SLBL" "$HEAL"' | .drift_warned[$s].grep = $t'
    maude_log_trace "drift" "kind=grep count=$GREP_COUNT"
  fi
fi

# --- Signal 2: Same Read target ≥3 times today ---
DUP="$(printf '%s\n' "$TAIL" | jq -r 'select(.tool == "Read" and .target != null) | .target' 2>/dev/null | sort | uniq -c | awk '$1 >= 3 {print}' | sort -rn | head -1)"
if [ -n "$DUP" ]; then
  COUNT="$(printf '%s' "$DUP" | awk '{print $1}')"
  TARGET="$(printf '%s' "$DUP" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
  WARNED="$(jq -r --arg s "$SLBL" --arg t "$TARGET" '.drift_warned[$s].read_targets[$t] // ""' "$CARE" 2>/dev/null)"
  if [ "$WARNED" != "$TODAY" ]; then
    BASE="$(basename "$TARGET")"
    printf 'Maude: noticed Claude has Read %s %d times today. Worth checking what he is looking for.\n' "$BASE" "$COUNT" >&2
    # Record this target's cooldown AND prune stale-dated keys in one write — the
    # cooldown only cares about TODAY, so yesterday's entries are cruft. Without this,
    # read_targets grew one key per distinct over-read file, forever (care.json bloat).
    maude_care_set "$CARE" --arg s "$SLBL" --arg t "$TARGET" --arg today "$TODAY" \
      "$HEAL"' | .drift_warned[$s].read_targets = ((.drift_warned[$s].read_targets // {}) | with_entries(select(.value == $today)) + {($t): $today})'
    maude_log_trace "drift" "kind=read target=$BASE count=$COUNT"
  fi
fi

exit 0
