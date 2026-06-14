#!/usr/bin/env bash
# Maude session-start hook — degradative brief across every reachable memory source.
# Reads: Anthropic auto-memory, .remember/, user-global home, house-map.
# Never blocks startup. Each missing tier is silently skipped.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
USER_DIR="$(maude_user_dir)"
REMEMBER="$PROJ/.remember"
MAP="$(maude_map_path)"

# ── Once-per-session housekeeping ────────────────────────────────────────────
# SessionStart is the once-per-start hook (it fires at each start/resume/clear/
# compact, not per turn), so it's the natural chokepoint for:
#   1. Pruning append-only artifacts (trace JSONL, pre-compact snapshots) past
#      the retention window — they grew unbounded before.
#   2. A single jq-missing notice. Without jq the irreversible-command gate is
#      fail-OPEN (silently disabled), and drift-watch / tier-1 / watch-list
#      nudges are off too. This is a SAFETY notice, not cosmetic — so it must
#      fire even when there's no memory to brief (i.e. before the early-exit).
maude_retention_sweep
if ! command -v jq >/dev/null 2>&1; then
  printf 'Maude: jq not found — the irreversible-command gate is OFF this session (fail-open), and drift-watch, tier-1, and watch-list nudges are disabled. Install jq to restore them.\n' >&2
fi

# Collect signals across every available tier — degradative, each independent.
NOW_LINE=""
REMEMBER_HANDOFF=""
PATTERN_HINT=""
LETTER_LINE=""
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

# Tier 3b: her letter to her next self (written at /maude:rest — read-only here,
# like every hook). First non-header, non-blank line is the essence; the wake/brief
# commands read the whole letter.
LETTER_LINE=""
if [ -s "$USER_DIR/letter-from-maude.md" ]; then
  LETTER_LINE="$(grep -m1 -v -E '^#|^[[:space:]]*$' "$USER_DIR/letter-from-maude.md" 2>/dev/null | head -c 160)"
fi

# Tier 4: house-map status
[ -f "$MAP" ] && HAS_MAP="✓"

# Tier 5: simple count of memory files in Anthropic dir
[ -d "$MEM" ] && TOPIC_COUNT="$(find "$MEM" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')"

# If nothing meaningful to surface, stay quiet.
if [ -z "$NOW_LINE" ] && [ -z "$REMEMBER_HANDOFF" ] && [ -z "$PATTERN_HINT" ] && [ -z "$LETTER_LINE" ] && [ -z "$HAS_MAP" ] && [ "$TOPIC_COUNT" -eq 0 ]; then
  exit 0
fi

# Compose brief — terse, one stanza per signal that fired.
# Greet by the user's local clock when the timezone is known (house-map);
# stay time-neutral otherwise — never assert a time-of-day from the box clock.
GREETING="$(maude_greeting)"
{
  [ -n "$GREETING" ] && printf '%s ' "$GREETING"
  printf 'Maude here.'
  [ -n "$HAS_MAP" ] && printf ' (house-map ✓)'
  printf '\n'
  [ -n "$REMEMBER_HANDOFF" ] && printf '  Last handoff (.remember): %s\n' "$REMEMBER_HANDOFF"
  [ -n "$NOW_LINE" ]          && printf '  Anthropic now: %s\n' "$NOW_LINE"
  [ -n "$PATTERN_HINT" ]      && printf '  Cross-project pattern: %s\n' "$PATTERN_HINT"
  [ -n "$LETTER_LINE" ]       && printf '  Letter from my last self: %s\n' "$LETTER_LINE"
  [ "$TOPIC_COUNT" -gt 0 ]    && printf '  %s memory file(s) on hand.\n' "$TOPIC_COUNT"
  [ -z "$HAS_MAP" ] && { [ -d "$REMEMBER" ] || [ -d "$MEM" ]; } && printf '  No house-map yet — run /maude:found.\n'
} 2>/dev/null

exit 0
