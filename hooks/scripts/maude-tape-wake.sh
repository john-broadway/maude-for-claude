#!/usr/bin/env bash
# SessionStart: play Maude's tape — the video that brings amnesiac Claude back.
#
# Prints the current canon (the user's verbatim words), the never-render list
# (phrasings they've rejected), and the tape's identity to STDOUT, which Claude
# Code injects as session context. This is the 50-First-Dates wake: the next
# Claude wakes already knowing what got corrected, so a cut scene (a rejected
# line) can't be re-served the way it was on 2026-07-17.
#
# Silent on an empty tape (fresh install, no data yet). Degrades silently:
# missing python3 or missing tape db -> exit 0, no output. Never blocks.
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_python3_ok || exit 0

DB="$(maude_project_dir)/.maude/plugin/tape/tape.db"
[ -f "$DB" ] || exit 0

PYTHONPATH="${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" python3 -m maude_tape wake --db "$DB" 2>/dev/null
exit 0
