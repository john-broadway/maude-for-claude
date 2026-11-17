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

# A rest cut short at the last exit: a rest.cut.<pid> mark whose process is gone
# (maude-tape-rest.sh). A mark whose process is alive is a rest still running in another
# session, not a cut, and is left alone. Finish the cut one before the tape plays, so the
# wake plays his words whole, and say so once. Bounded well inside this hook's timeout; a
# rest that cannot finish now keeps the marks for the next wake.
CUTS=()
for m in "$(dirname "$DB")"/rest.cut.*; do
  [ -f "$m" ] && [ ! -L "$m" ] || continue
  pid="${m##*/rest.cut.}"               # the whole rest of the name, digits only: a
  case "$pid" in ''|*[!0-9]*) continue ;; esac   # moved-aside rest.cut.N.notafile.M is not one
  kill -0 "$pid" 2>/dev/null && continue
  # Another user's live process answers "not permitted": alive, not cut.
  case "$(kill -0 "$pid" 2>&1)" in *[Pp]ermitted*) continue ;; esac
  CUTS+=("$m")
done
if [ "${#CUTS[@]}" -gt 0 ]; then
  if maude_timeout 4 python3 -I -c "$MAUDE_PY_BOOT" "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_tape rest --db "$DB" >/dev/null 2>&1; then
    for m in "${CUTS[@]}"; do rm -f "$m" 2>/dev/null; done
    printf "**Maude:** the last session's tape rest did not finish; it is finished now.\n"
  else
    printf "**Maude:** the last session's tape rest did not finish, and could not be finished now; it stays marked until a rest runs to its end.\n"
  fi
fi

python3 -I -c "$MAUDE_PY_BOOT" "${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" maude_tape wake --db "$DB" 2>/dev/null
exit 0
