#!/usr/bin/env bash
# Maude SessionEnd hook — the true end-of-session stitch.
#
# Unlike Stop (which fires on every assistant pause and therefore writes NO
# handoff — see maude-session-stop.sh), SessionEnd fires on a REAL end:
# exit, logout, or /clear. That makes a modest auto-write safe here:
#
#   1. Always: log a session-end trace event with the reason (audit).
#   2. Always (jq): stamp care.json .last_session_end.
#   3. If the session leaves 3+ uncaptured exchanges (same arithmetic as the
#      SessionStart continuity guard — shared helpers, one definition) AND
#      the handoff slot (.remember/remember.md) is empty or absent, leave a
#      ONE-LINE auto-note pointing the next session at the trace.
#
# The auto-note NEVER overwrites a non-empty handoff — a fresh /maude:rest
# write always wins. It is labeled as an auto-note so the next session knows
# it is a pointer, not a composed handoff.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

INPUT="$(cat 2>/dev/null)"

REASON=""
if command -v jq >/dev/null 2>&1; then
  REASON="$(printf '%s' "$INPUT" | jq -r '.reason // ""' 2>/dev/null)"
fi
[ -z "$REASON" ] && REASON="unknown"

maude_log_trace "session-end" "reason=$REASON"

command -v jq >/dev/null 2>&1 || exit 0

CARE="$(maude_self_dir)/care.json"
maude_care_ensure "$CARE"
maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_session_end = $ts'

# ── Auto-note (only into an EMPTY slot, only when work went uncaptured) ──
REMEMBER="$(maude_remember_dir)"
[ -d "$REMEMBER" ] || exit 0          # no continuity substrate → N/A
HANDOFF="$REMEMBER/remember.md"
[ -s "$HANDOFF" ] && exit 0           # a real handoff exists — never clobber

N="$(maude_uncaptured_prompt_count)"
[ "${N:-0}" -ge 3 ] || exit 0

printf 'Auto-note from Maude (session ended: %s): ~%s exchanges were never saved to a handoff. /maude:wake reconstructs them from the trace.\n' \
  "$REASON" "$N" > "$HANDOFF" 2>/dev/null
maude_log_trace "session-end" "auto-note prompts=$N"

exit 0
