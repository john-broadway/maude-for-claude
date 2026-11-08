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
# And the voice profile, from his typed lines only: it was last recomputed by hand on
# 2026-08-14, ten weeks stale, while the corpus grew from 1,852 lines to 4,928. 0.44 s on
# the real tape (2026-10-25); bounded so a slow box cannot eat the SessionEnd budget.
# Flag the voice rows that were a suggested prompt he accepted (the live capture cannot
# tell: it sees only the text). Never deletes. The whole hook has 10 s (hooks.json), and a
# first pass over a big transcripts dir takes about that alone (lens 4: 9.9 s on 109 files),
# so the pass starts no new transcript after 4 s and is killed at 6. It commits each file it
# finishes and skips a file it has read whole, so the next rest goes on where this one
# stopped. Before the profile, so the profile never counts a line flagged here.
TRANSCRIPTS="$(dirname "$(maude_mem_dir)")"
if [ -d "$TRANSCRIPTS" ]; then
  PYTHONPATH="${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_timeout 6 python3 -m maude_tape voice-flag \
    --db "$DB" --transcripts "$TRANSCRIPTS" --budget 4 >/dev/null 2>&1
fi
PYTHONPATH="${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_timeout 3 python3 -m maude_tape profile --db "$DB" >/dev/null 2>&1
exit 0
