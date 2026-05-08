#!/usr/bin/env bash
# Maude subagent-stop hook (during).
# When a subagent finishes, log a one-line marker. If the subagent was the maude
# subagent, optionally surface its summary (Claude Code passes the result via stdin).

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

NAME=""
if command -v jq >/dev/null 2>&1; then
  NAME="$(jq -r '.subagent_type // .agent // ""' 2>/dev/null)"
fi

maude_log_trace "subagent-stop" "agent=${NAME:-unknown}"

exit 0
