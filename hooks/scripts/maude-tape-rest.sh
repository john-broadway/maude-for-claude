#!/usr/bin/env bash
# SessionEnd: close the tape's loop — consolidate the session's signal into canon
# (autolearning), forget the noise. Silent + non-blocking.
#
# This is the arc that failed on 2026-07-17: work captured a correction, but rest
# never consolidated it, so the next wake played a cut reel. Wiring rest here
# closes the cycle: wake -> work -> REST -> wake.
#
# Degrades silently: missing python3 or missing tape db -> exit 0.
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_python3_ok || exit 0

DB="$(maude_project_dir)/.maude/plugin/tape/tape.db"
[ -f "$DB" ] || exit 0

PYTHONPATH="${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" python3 -m maude_tape rest --db "$DB" >/dev/null 2>&1
exit 0
