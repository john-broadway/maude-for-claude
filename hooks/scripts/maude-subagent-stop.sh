#!/usr/bin/env bash
# Maude subagent-stop hook (during).
# When a subagent finishes, log a one-line marker. If the subagent was the maude
# subagent, optionally surface its summary (Claude Code passes the result via stdin).

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Read stdin ONCE: the promote below needs the same envelope. The harness's SubagentStop
# stdin carries agent_id on every stop (read from the trace rows, 2026-09-06); agent_type
# only on stops of Agent-tool dispatches (3 of 906 stops that day; the rest are the
# harness's own subagents and log as unknown). The id is what ties this stop back to
# the launch that is waiting on it, and a stop's agent_id equals its launch's agentId
# (proven live at 19:59:10Z: the 24th lens's stop promoted its own pending entry).
INPUT="$(cat 2>/dev/null)"
NAME=""
AID=""
if command -v jq >/dev/null 2>&1; then
  NAME="$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // .agent // ""' 2>/dev/null)"
  AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)"
fi

maude_log_trace "subagent-stop" "agent=${NAME:-unknown}${AID:+ id=${AID:0:8}}"

# A background lens leaves a PENDING stamp at launch (redteam-watch); this stop is the
# moment it becomes a real one. Only when this id is in care.json at all: every stop
# carries an id and almost none is a lens (the 24th lens, IMPORTANT-3: 131 shell-outs in
# ninety minutes, each a bash, the lib, and a jq over 33 KB, to promote nothing).
# The exact question, not a substring: a text match also fired on an id that appears only
# as a git ref in someone's stamp (the 25th lens, MINOR-9).
CARE="$(maude_self_dir)/care.json"
if [ -n "$AID" ] && [ -f "$CARE" ] \
   && jq -e --arg a "$AID" '(.redteam_pending // {}) | has($a)' "$CARE" >/dev/null 2>&1; then
  printf '%s' "$INPUT" | bash "$DIR/maude-redteam-watch.sh" promote 2>/dev/null
fi

exit 0
