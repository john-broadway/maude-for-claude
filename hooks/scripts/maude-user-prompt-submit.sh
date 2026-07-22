#!/usr/bin/env bash
# Maude user-prompt-submit hook (during).
# If the prompt mentions a topic the house-map flags, surface a one-liner.
# Reads stdin (Claude Code passes hook input as JSON on stdin).
# Always exits 0 — never blocks.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_have_map || exit 0

# Read user prompt from stdin JSON. Fail-silent if jq isn't around or input isn't JSON.
PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(jq -r '.prompt // .message // ""' 2>/dev/null)"
fi
[ -z "$PROMPT" ] && exit 0

MAP="$(maude_map_path)"

# Pull the watch-list section out of the map. Lightweight — just the bullet lines.
WATCH="$(awk '/^## Watch list/{flag=1; next} /^## /{flag=0} flag' "$MAP" 2>/dev/null)"
[ -z "$WATCH" ] && exit 0

# For each watched item, see if the prompt mentions the basename or the term.
HITS=""
while IFS= read -r line; do
  # Extract the path/term from a bullet like "- .claude/CLAUDE.md"
  TERM="$(printf '%s' "$line" | sed -E 's/^[-* ]+//; s/[[:space:]]*$//')"
  [ -z "$TERM" ] && continue
  BASE="$(basename "$TERM")"
  if printf '%s' "$PROMPT" | grep -qiF -- "$BASE" 2>/dev/null; then
    HITS="${HITS}${TERM}, "
  fi
done <<< "$WATCH"

if [ -n "$HITS" ]; then
  MSG="Maude: heads up — your prompt touches ${HITS%, }"
  printf '%s\n' "$MSG" >&2
  # #49: injected context logs its bill (hook + bytes, never content).
  maude_log_spend "watch-list" "$(printf '%s' "$MSG" | wc -c | tr -d ' ')"
fi

exit 0
