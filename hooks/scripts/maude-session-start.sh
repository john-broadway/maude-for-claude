#!/usr/bin/env bash
# Maude session-start hook — degradative brief across every reachable memory source.
# Reads: Anthropic auto-memory, .remember/, user-global home, house-map.
# Never blocks startup. Each missing tier is silently skipped.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
SELF="$(maude_self_dir)"
USER_DIR="$(maude_user_dir)"
REMEMBER="$PROJ/.remember"
MAP="$(maude_map_path)"

# Collect signals across every available tier — degradative, each independent.
NOW_LINE=""
REMEMBER_HANDOFF=""
PATTERN_HINT=""
HAS_MAP=""
TOPIC_COUNT=0

# Tier 1: Anthropic auto-memory live buffer
if [ -f "$MEM/now.md" ]; then
  NOW_LINE="$(grep -m1 -E '^## [0-9]{2}:[0-9]{2}' "$MEM/now.md" | head -c 200)"
  [ -z "$NOW_LINE" ] && NOW_LINE="$(head -1 "$MEM/now.md" | head -c 200)"
fi

# Tier 2: remember plugin's handoff file (the dense, intentional signal from last session)
if [ -s "$REMEMBER/remember.md" ]; then
  REMEMBER_HANDOFF="$(grep -m1 -A1 '^## Next' "$REMEMBER/remember.md" 2>/dev/null | tail -1 | head -c 200)"
  [ -z "$REMEMBER_HANDOFF" ] && REMEMBER_HANDOFF="$(head -3 "$REMEMBER/remember.md" | tail -1 | head -c 200)"
fi

# Tier 3: cross-project patterns (her own home base)
if [ -s "$USER_DIR/patterns.md" ]; then
  PATTERN_HINT="$(grep -m1 -i "$(basename "$PROJ")" "$USER_DIR/patterns.md" 2>/dev/null | head -c 160)"
fi

# Tier 4: house-map status
[ -f "$MAP" ] && HAS_MAP="✓"

# Tier 5: simple count of memory files in Anthropic dir
[ -d "$MEM" ] && TOPIC_COUNT="$(find "$MEM" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')"

# If nothing meaningful to surface, stay quiet.
if [ -z "$NOW_LINE" ] && [ -z "$REMEMBER_HANDOFF" ] && [ -z "$PATTERN_HINT" ] && [ -z "$HAS_MAP" ] && [ "$TOPIC_COUNT" -eq 0 ]; then
  exit 0
fi

# Compose brief — terse, one stanza per signal that fired.
{
  printf 'Maude here.'
  [ -n "$HAS_MAP" ] && printf ' (house-map ✓)'
  printf '\n'
  [ -n "$REMEMBER_HANDOFF" ] && printf '  Last handoff (.remember): %s\n' "$REMEMBER_HANDOFF"
  [ -n "$NOW_LINE" ]          && printf '  Anthropic now: %s\n' "$NOW_LINE"
  [ -n "$PATTERN_HINT" ]      && printf '  Cross-project pattern: %s\n' "$PATTERN_HINT"
  [ "$TOPIC_COUNT" -gt 0 ]    && printf '  %s memory file(s) on hand.\n' "$TOPIC_COUNT"
  [ -z "$HAS_MAP" ] && [ -d "$REMEMBER" -o -d "$MEM" ] && printf '  No house-map yet — run /maude:found.\n'
} 2>/dev/null

exit 0
