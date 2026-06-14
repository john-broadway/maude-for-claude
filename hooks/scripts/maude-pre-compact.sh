#!/usr/bin/env bash
# Maude pre-compact hook (during).
# Fires before context compaction. Snapshots the live buffer so it isn't lost.
# Writes to:
#   - <project>/.maude/plugin/snapshots/precompact-YYYY-MM-DDTHHMMZ.md
#       Markdown snapshot of the live buffer (HER closet, never Anthropic memory).
#   - .remember/remember.md (handoff, only if stale > 600s and no save lock)
#       Lets the remember plugin's pipeline absorb the handoff.
#   - JSONL event in <project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl
#       Marks that pre-compact happened, references the snapshot path.
# Buffer content is passed through maude_redact (best-effort masking of obvious
# secret shapes — API keys, JWTs, PEM keys, URL basic-auth) before write. This is
# BEST-EFFORT, not a guarantee of completeness; the snapshot dir is gitignored and
# should be wiped at session-end as routine hygiene.
# Never blocks. Idempotent within the same minute.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
REMEMBER="$PROJ/.remember"
SELF="$(maude_self_dir)"

TIME="$(date +%H:%M)"
STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
SOURCED=""

# Find the live buffer (Anthropic-side first, then remember-side as fallback)
NOW_FILE=""
[ -f "$MEM/now.md" ] && NOW_FILE="$MEM/now.md"
[ -z "$NOW_FILE" ] && [ -f "$REMEMBER/now.md" ] && NOW_FILE="$REMEMBER/now.md"

# Tier 1: snapshot to project-local snapshots dir
SNAPSHOT_PATH=""
if [ -n "$NOW_FILE" ]; then
  SNAPSHOTS_DIR="$SELF/snapshots"
  mkdir -p "$SNAPSHOTS_DIR" 2>/dev/null
  SNAPSHOT_PATH="$SNAPSHOTS_DIR/precompact-$STAMP.md"

  # Snapshot the buffer through best-effort redaction (maude_redact masks obvious
  # secret shapes). Best-effort, not a guarantee — the snapshots dir is gitignored
  # (.maude/plugin/* is self-ignored); wipe at session-end as routine hygiene.
  printf '# Pre-compact snapshot — %s\n\nSource: %s\n\n---\n\n%s\n' \
    "$STAMP" "$NOW_FILE" "$(head -200 "$NOW_FILE" 2>/dev/null | maude_redact)" \
    > "$SNAPSHOT_PATH" 2>/dev/null
  SOURCED="${SOURCED}snapshot "
fi

# Tier 2: remember plugin handoff file (with redaction + staleness check)
if [ -d "$REMEMBER" ] && [ ! -f "$REMEMBER/tmp/save.lock" ] && [ -n "$NOW_FILE" ]; then
  HANDOFF="$REMEMBER/remember.md"
  WRITE_HANDOFF=1
  if [ -s "$HANDOFF" ]; then
    HANDOFF_AGE=$(( $(date +%s) - $(stat -c %Y "$HANDOFF" 2>/dev/null || echo 0) ))
    [ "$HANDOFF_AGE" -lt 600 ] && WRITE_HANDOFF=0
  fi

  if [ "$WRITE_HANDOFF" -eq 1 ]; then
    BUFFER_HEAD="$(head -20 "$NOW_FILE" 2>/dev/null | maude_redact | sed 's/^/  /')"
    {
      printf '# Handoff\n\n'
      printf '## State\n'
      printf 'Pre-compact snapshot at %s. Live buffer (top 20 lines):\n' "$TIME"
      printf '%s\n' "$BUFFER_HEAD"
      printf '\n## Next\n'
      printf -- '- Resume from where compaction interrupted.\n'
      [ -n "$SNAPSHOT_PATH" ] && printf -- '- Full snapshot: %s\n' "$SNAPSHOT_PATH"
      printf '\n## Context\n'
      printf 'Snapshot taken automatically by Maude before Claude Code compaction.\n'
    } > "$HANDOFF" 2>/dev/null
    SOURCED="${SOURCED}remember "
  fi
fi

# Tier 3: JSONL event marker in the per-turn trace
maude_log_trace "pre-compact" "snapshot=${SNAPSHOT_PATH:-none} sourced=${SOURCED% }"

# Surface a brief note if we actually snapshotted somewhere
if [ -n "$SOURCED" ]; then
  printf 'Maude: pre-compact snapshot to: %s\n' "${SOURCED% }" >&2
fi

exit 0
