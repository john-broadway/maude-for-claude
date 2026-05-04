#!/usr/bin/env bash
# Maude pre-compact hook (during).
# Fires before context compaction. Snapshots the live buffer to:
#   - Anthropic today-*.md (so next-session Claude sees it)
#   - .remember/remember.md (so remember's pipeline absorbs the handoff too)
# Never blocks. Idempotent within the same minute.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
REMEMBER="$PROJ/.remember"

TIME="$(date +%H:%M)"
TODAY="$(date +%Y-%m-%d)"
SOURCED=""

# Tier 1: Anthropic auto-memory snapshot
NOW_FILE=""
[ -f "$MEM/now.md" ] && NOW_FILE="$MEM/now.md"
[ -z "$NOW_FILE" ] && [ -f "$REMEMBER/now.md" ] && NOW_FILE="$REMEMBER/now.md"

if [ -n "$NOW_FILE" ] && [ -d "$MEM" ]; then
  TODAY_FILE="$MEM/today-$TODAY.md"
  [ -f "$TODAY_FILE" ] || printf '# %s\n\n' "$TODAY" > "$TODAY_FILE"

  LAST="$(tail -1 "$TODAY_FILE" 2>/dev/null)"
  if ! printf '%s' "$LAST" | grep -q "pre-compact $TIME"; then
    {
      printf '\n## %s | pre-compact snapshot\n' "$TIME"
      head -200 "$NOW_FILE"
      printf '\n'
    } >> "$TODAY_FILE"
    SOURCED="${SOURCED}anthropic "
  fi
fi

# Tier 2: remember plugin handoff file
# Only write if .remember/ exists AND remember.md isn't actively being held by remember's lock
if [ -d "$REMEMBER" ] && [ ! -f "$REMEMBER/tmp/save.lock" ]; then
  HANDOFF="$REMEMBER/remember.md"
  # Compose a minimal handoff in remember's expected format.
  # Don't clobber an existing fresh handoff — only write if file is empty or older than 10 min.
  WRITE_HANDOFF=1
  if [ -s "$HANDOFF" ]; then
    HANDOFF_AGE=$(( $(date +%s) - $(stat -c %Y "$HANDOFF" 2>/dev/null || echo 0) ))
    [ "$HANDOFF_AGE" -lt 600 ] && WRITE_HANDOFF=0
  fi

  if [ "$WRITE_HANDOFF" -eq 1 ] && [ -n "$NOW_FILE" ]; then
    {
      printf '# Handoff\n\n'
      printf '## State\n'
      printf 'Pre-compact snapshot at %s. Live buffer (top 20 lines):\n' "$TIME"
      head -20 "$NOW_FILE" | sed 's/^/  /'
      printf '\n## Next\n'
      printf '- Resume from where compaction interrupted.\n'
      printf '\n## Context\n'
      printf 'Snapshot taken automatically by Maude before Claude Code compaction. '
      printf 'Full live buffer remains in %s and Anthropic today-%s.md.\n' "$NOW_FILE" "$TODAY"
    } > "$HANDOFF" 2>/dev/null
    SOURCED="${SOURCED}remember "
  fi
fi

# Surface a brief note if we actually snapshotted somewhere
if [ -n "$SOURCED" ]; then
  printf 'Maude: pre-compact snapshot to: %s\n' "${SOURCED% }" >&2
fi

exit 0
