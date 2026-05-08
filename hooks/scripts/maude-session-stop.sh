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
# Cost: if the user quits without /maude:rest, no auto-handoff is left in
# .remember/. That's the price of avoiding false-positive writes mid-session.
#
# We log a JSONL event to the project-local trace so the audit still shows
# every Stop. Cheap, append-only, lives in HER closet.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_log_trace "stop" ""

exit 0
