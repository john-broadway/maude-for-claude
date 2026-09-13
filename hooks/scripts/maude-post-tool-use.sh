#!/usr/bin/env bash
# Maude post-tool-use hook (post-).
# Fires after Write/Edit/MultiEdit. Two jobs:
#   1. RULES rail (design law) — classify the written file, whisper the law once per class,
#      lint a schema, stamp a design that names its laws. Called from here, not registered in
#      hooks.json: registry entries are COLD until /reload-plugins; script edits are live.
#      Sits ABOVE the house-map guard on purpose: a project with no map still gets the rail.
#   2. If the changed path is on the house-map watch list, log the change to the trace.
# Always exits 0.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Read stdin ONCE. Two consumers share it; a second jq on the same stream reads nothing,
# which is how `tool=` silently defaulted to "write" for every watched-path line before this.
INPUT="$(cat 2>/dev/null)"

printf '%s' "$INPUT" | bash "$DIR/maude-rules-watch.sh" classify

# THE AUTO-MEMORY INDEX HAS A LOAD LIMIT. Claude Code loads <slug>/memory/MEMORY.md at
# session start and stops past ~24.4 KB, measured in UTF-16 units (JavaScript's string
# length: an emoji counts 2, so a byte count overstates and a character count
# understates). The cut is one transcript line and no error; this index sat over the
# limit for two sessions (2026-09-05/06) and the laws at its tail never loaded. Say it
# at the write. Sits above the house-map guard like the rules rail: no map needed.
_FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
case "$_FP" in
  # The auto-loaded index only; the limit quoted below is the loader's (the 24th lens,
  # MINOR-8). The price, named: the same real file reached through a symlinked ~/.claude
  # (a path that does not spell `.claude`) is missed. One missed whisper, never a false
  # one, which is the direction this rail fails in everywhere else (the 25th, MINOR-3).
  */.claude/projects/*/memory/MEMORY.md)
    if [ -f "$_FP" ]; then
      _UNITS=""
      if maude_python3_ok; then
        _UNITS="$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace").read().encode("utf-16-le")) // 2)' "$_FP" 2>/dev/null)"
      fi
      # Without python, characters are a floor, and not a close one: an emoji is two units
      # read as one (a file of them is silent at twice the limit), and invalid UTF-8 reads 0
      # (silent, not late). The no-python3 adopter's problem; the loader counts units.
      [ -n "$_UNITS" ] || _UNITS="$(wc -m < "$_FP" 2>/dev/null | tr -d ' ')"
      if [ "${_UNITS:-0}" -ge 23500 ] 2>/dev/null; then
        printf 'Maude: MEMORY.md is %s KB against Claude Code'"'"'s 24.4 KB load limit (UTF-16 units, the way the loader counts). Past it the tail never loads and nothing says so. Compact it: cut closed detail, never a law; archive the lines verbatim.\n' \
          "$(awk -v u="$_UNITS" 'BEGIN{printf "%.1f", u/1024}')" >&2
      fi
    fi ;;
esac

maude_have_map || exit 0

TARGET=""
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TARGET="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
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
