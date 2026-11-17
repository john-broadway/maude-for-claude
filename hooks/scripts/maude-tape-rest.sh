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

# The cut marker: SessionEnd hooks are cancelled when a session exits under them, and a rest
# cut short is otherwise silent. Each rest marks itself (rest.cut.<its pid>) while it runs
# and clears its own mark when it ends, so the next wake (maude-tape-wake.sh) finds a mark
# whose process is gone only when that rest did not finish; another session's rest still
# running is alive, and its mark is left alone. A canon line and its event's mark commit
# together, and a mark moves only a still-buffered event, so finishing it twice is safe.
# Never written THROUGH: a link or a non-file at the path is moved aside first (the gate's
# own marker rule), and the write is no-clobber, so a planted symlink truncates nothing.
CUT="$(dirname "$DB")/rest.cut.$$"
_maude_care_marker_path_clear "$CUT" && ( set -C; : > "$CUT" ) 2>/dev/null
python3 -I -c "$MAUDE_PY_BOOT" "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_tape rest --db "$DB" >/dev/null 2>&1 \
  && rm -f "$CUT" 2>/dev/null
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
  maude_timeout 6 python3 -I -c "$MAUDE_PY_BOOT" "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_tape voice-flag \
    --db "$DB" --transcripts "$TRANSCRIPTS" --budget 4 >/dev/null 2>&1
fi
maude_timeout 3 python3 -I -c "$MAUDE_PY_BOOT" "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_tape profile --db "$DB" >/dev/null 2>&1
exit 0
