#!/usr/bin/env bash
# Maude Stop hook — fires every time the assistant pauses, NOT only at session-end.
#
# Claude Code's `Stop` event triggers on every assistant-stops-talking moment,
# of which there can be many in a single session. We can't reliably detect
# "real session end" from this signal.
#
# Trade-off: we therefore do NOT auto-write a handoff to .remember/remember.md
# from this hook (it would clobber a fresh /maude:save), and we do NOT append
# to recent.md (it would accumulate dozens of lines per real session). For
# explicit session-end actions, the user invokes /maude:rest.
#
# Cost: this hook itself leaves no handoff. The SessionEnd stitch
# (maude-session-end.sh) now covers the real-end case — it fires only on a
# true end and may leave a one-line auto-note in an EMPTY handoff slot.
#
# We log a JSONL event to the project-local trace so the audit still shows
# every Stop. Cheap, append-only, lives in HER closet.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_log_trace "stop" ""

# Chore dispatch (docs/specs/2026-07-16-chore-ledger-design.md). Stop fires on
# every pause; the detector threshold + per-chore flock make this self-limiting.
# The old no-handoff-from-Stop rule stands for THIS hook's own writes — the c1
# doer has its own clobber guard (append-only into a non-empty remember.md,
# write only into an empty/absent slot — never a replace).
TRANSCRIPT="$(timeout 2 head -c 4096 2>/dev/null | jq -r '.transcript_path // empty' 2>/dev/null)"
CHORES="$DIR/../../scripts/maude-chores.sh"
if [ -f "$CHORES" ]; then
  bash "$CHORES" detect >/dev/null 2>&1
  bash "$CHORES" dispatch "$TRANSCRIPT" >/dev/null 2>&1
fi

exit 0
