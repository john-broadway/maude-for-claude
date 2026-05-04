#!/usr/bin/env bash
# Maude session-stop hook (post-).
# Fans out a session-end marker across every reachable memory tier.
# Anthropic recent.md + .remember/remember.md (if not already populated this session).
# Never blocks Stop. Each tier independent.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
REMEMBER="$PROJ/.remember"
SELF="$(maude_self_dir)"

TODAY="$(date +%Y-%m-%d)"
TIME="$(date +%H:%M)"

# Tier 1: Anthropic auto-memory recent.md marker
if [ -d "$MEM" ]; then
  RECENT="$MEM/recent.md"
  [ -f "$RECENT" ] || printf '# Recent\n\n' > "$RECENT"
  LAST_LINE="$(tail -1 "$RECENT" 2>/dev/null)"
  if ! printf '%s' "$LAST_LINE" | grep -q "session-stop $TODAY $TIME"; then
    printf -- '- session-stop %s %s\n' "$TODAY" "$TIME" >> "$RECENT"
  fi
fi

# Tier 2: .remember/remember.md — write a minimal handoff IF empty or stale (>1hr)
# Don't clobber a fresh /maude:save or /remember handoff.
if [ -d "$REMEMBER" ] && [ ! -f "$REMEMBER/tmp/save.lock" ]; then
  HANDOFF="$REMEMBER/remember.md"
  WRITE=1
  if [ -s "$HANDOFF" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$HANDOFF" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 3600 ] && WRITE=0
  fi
  if [ "$WRITE" -eq 1 ]; then
    NOW_LINE="(no live buffer)"
    if [ -f "$MEM/now.md" ]; then
      NOW_LINE="$(head -3 "$MEM/now.md" | tr '\n' ' ' | head -c 200)"
    elif [ -f "$REMEMBER/now.md" ]; then
      NOW_LINE="$(head -3 "$REMEMBER/now.md" | tr '\n' ' ' | head -c 200)"
    fi
    {
      printf '# Handoff\n\n'
      printf '## State\n'
      printf 'Session ended %s %s without an explicit /maude:save. Live buffer at stop:\n' "$TODAY" "$TIME"
      printf '  %s\n' "$NOW_LINE"
      printf '\n## Next\n'
      printf '- Run /maude:wake on next session to re-orient.\n'
      printf '\n## Context\n'
      printf 'Auto-written by Maude session-stop hook. Anthropic memory has the full daily.\n'
    } > "$HANDOFF" 2>/dev/null
  fi
fi

# Tier 3: Maude's own trace — record session-stop event
if [ -d "$SELF/trace" ]; then
  TRACE="$SELF/trace/today-$TODAY.jsonl"
  printf '{"ts":"%s","kind":"session-stop"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE"
fi

exit 0
