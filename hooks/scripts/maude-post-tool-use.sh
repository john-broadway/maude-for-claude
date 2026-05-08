#!/usr/bin/env bash
# Maude post-tool-use hook (post-).
# Fires after Write/Edit/MultiEdit. If the changed path is on the watch list,
# log the change to today's daily file so future sessions see what touched what.
# Always exits 0.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_have_map || exit 0

TARGET=""
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TARGET="$(jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
  TOOL="$(jq -r '.tool_name // ""' 2>/dev/null)"
fi
[ -z "$TARGET" ] && exit 0

MAP="$(maude_map_path)"
WATCH_SECTION="$(awk '/^## Watch list/{flag=1; next} /^## /{flag=0} flag' "$MAP" 2>/dev/null)"
[ -z "$WATCH_SECTION" ] && exit 0

while IFS= read -r line; do
  TERM="$(printf '%s' "$line" | sed -E 's/^[-* ]+//; s/[[:space:]]*$//')"
  [ -z "$TERM" ] && continue
  case "$TARGET" in
    *"$TERM"*)
      maude_log_trace "post-tool" "tool=${TOOL:-write} target=$TARGET"
      break
      ;;
  esac
done <<< "$WATCH_SECTION"

exit 0
