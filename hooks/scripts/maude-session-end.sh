#!/usr/bin/env bash
# Maude SessionEnd hook — the true end-of-session stitch.
#
# Unlike Stop (which fires on every assistant pause and therefore writes NO
# handoff — see maude-session-stop.sh), SessionEnd fires on a REAL end:
# exit, logout, or /clear.
#
#   1. Always: log a session-end trace event with the reason (audit).
#   2. Always (jq): stamp care.json .last_session_end.
#
# It writes nothing into the remember plugin's store (retired 2026-11-11: that
# store is the remember plugin's own; uncaptured work is said by the continuity
# guard at the next wake).

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

# One rolling copy of each lane, for the wake's shrink check (maude-lane-copy.sh). Needs
# no jq. Called from here, not registered in hooks.json: a script edit is live on save.
bash "$(dirname "$0")/maude-lane-copy.sh" keep >/dev/null 2>&1

command -v jq >/dev/null 2>&1 || exit 0

CARE="$(maude_self_dir)/care.json"
maude_care_ensure "$CARE"
maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_session_end = $ts'

# The auto-note into the remember plugin's empty handoff slot is retired (2026-11-11):
# that store is the remember plugin's own. Uncaptured work is still said loudly, by the
# continuity guard at the next wake. Design: docs/specs/2026-11-11-the-circle-design.md.

exit 0
