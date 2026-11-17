#!/usr/bin/env bash
# Maude pre-compact hook (during).
# Fires before context compaction. Snapshots the live buffer so it isn't lost.
# Writes to:
#   - <project>/.maude/plugin/snapshots/precompact-YYYY-MM-DDTHHMMZ.md
#       Markdown snapshot of the live buffer (HER closet, never Anthropic memory).
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

MEM="$(maude_mem_dir)"
REMEMBER="$(maude_remember_dir)"
SELF="$(maude_self_dir)"

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
  # The buffer is one block (scripts/maude-now-write.sh); one written before the writer may
  # still be a stack, oldest-first, with the session being compacted at the TAIL. `head -200` saved the same 35-day-old 5% five times over (2026-09-06); take the
  # tail, and write the cut into the header so the reader knows what this is not.
  TOTAL_LINES="$(wc -l < "$NOW_FILE" 2>/dev/null | tr -d ' ')"; [ -n "$TOTAL_LINES" ] || TOTAL_LINES=0
  KEEP_LINES=200; [ "$TOTAL_LINES" -lt "$KEEP_LINES" ] && KEEP_LINES="$TOTAL_LINES"
  printf '# Pre-compact snapshot — %s\n\nSource: %s (last %s of %s lines)\n\n---\n\n%s\n' \
    "$STAMP" "$NOW_FILE" "$KEEP_LINES" "$TOTAL_LINES" "$(tail -n 200 "$NOW_FILE" 2>/dev/null | maude_redact)" \
    > "$SNAPSHOT_PATH" 2>/dev/null
  SOURCED="${SOURCED}snapshot "
fi

# Tier 2 (retired 2026-11-11): Maude no longer appends to the remember plugin's
# handoff. That store is the remember plugin's own; its /remember writes the handoff.
# Design: docs/specs/2026-11-11-the-circle-design.md ("What retires").

# Tier 3: JSONL event marker in the per-turn trace
maude_log_trace "pre-compact" "snapshot=${SNAPSHOT_PATH:-none} sourced=${SOURCED% }"

# Surface a brief note if we actually snapshotted somewhere
if [ -n "$SOURCED" ]; then
  printf 'Maude: pre-compact snapshot to: %s\n' "${SOURCED% }" >&2
fi

exit 0
