#!/usr/bin/env bash
# The prose leak shapes (scripts/ship-prose.sh) against the whole shipped tree: every prose
# line, not only a diff's added lines. A hit is either a false positive (narrow the shape)
# or a real leak (scrub it); a shape is never weakened to let a real one through. On
# 2026-11-16 this found three, all scrubbed before the shapes went into the audit.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/ship-prose.sh"

# The shipped files: tracked files minus the internal set when this is a checkout; every
# file when it is the smoke's archive (no .git there, and the internal set already gone).
# The internal set is stripped in BOTH cases: canon's own smoke archives HEAD whole, so an
# archive can still hold .publishignore and the files it names (the pooled runs of
# 2026-11-16 went red on exactly that: internal plans quote sessions, and never ship).
shipped_files() {
  local ign=()
  [ -f "$ROOT/.publishignore" ] && while IFS= read -r l; do ign+=("$l"); done \
    < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/.publishignore")
  {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$ROOT" ls-files
    else
      (cd "$ROOT" && find . -type f ! -path './.git/*' | sed 's|^\./||')
    fi
  } | while IFS= read -r f; do
    local skip=0 i
    for i in ${ign[@]+"${ign[@]}"}; do case "$f" in "$i"|"${i%/}"/*) skip=1 ;; esac; done
    [ "$skip" = 0 ] && printf '%s\n' "$f"
  done
}

test_start "no shipped prose line names a memory note or quotes a session id"
HITS=""
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  n="$(ship_prose_hits "$f" < "$ROOT/$f")"
  [ "${n:-0}" -gt 0 ] && HITS="$HITS $f($n)"
done < <(shipped_files)
assert_eq "$HITS" "" "prose hits"

test_start "the walk is not empty, and the shapes still fire (the calibration can go red)"
assert_ne "$(shipped_files | wc -l | tr -d ' ')" "0" "shipped file count"
assert_eq "$(printf 'see [[feedback_x-y]]\n' | ship_prose_hits a.md)" "1" "a note link in Markdown"
assert_eq "$(printf '# on that day session 1a2b3c4d ran\n' | ship_prose_hits a.sh)" "1" "a session id in a comment"
assert_eq "$(printf 'session %s\n' "$(printf 'ab12%.0s' 1 2 3 4 5 6 7 8)" | ship_prose_hits a.md)" "1" "32 hex in a row"
assert_eq "$(printf 'session-id: 1A2B3C4D\n' | ship_prose_hits a.md)" "1" "upper case, session-id:"
assert_eq "$(printf 'the sessionId=1a2b3c4d5e then\n' | ship_prose_hits a.md)" "1" "sessionId="
assert_eq "$(printf 'the session continued\n' | ship_prose_hits a.md)" "0" "plain prose about a session is not one"

print_summary
teardown_test_env
exit $FAILED
