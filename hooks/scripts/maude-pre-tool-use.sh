#!/usr/bin/env bash
# Maude pre-tool-use hook (pre-).
# Fires before Write/Edit/MultiEdit. Cross-references multiple sources before
# letting Claude touch a watched path:
#   - house-map watch list (project-local)
#   - cross-project patterns.md (user-global) — has she seen this kind of edit go wrong before?
# Surfaces a one-line nudge. Never blocks the tool call.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Tool input is JSON on stdin. Extract file_path.
TARGET=""
if command -v jq >/dev/null 2>&1; then
  TARGET="$(jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
fi
[ -z "$TARGET" ] && exit 0

USER_DIR="$(maude_user_dir)"
SURFACED=""

# Check 1: project-local watch list from house-map
if maude_have_map; then
  MAP="$(maude_map_path)"
  WATCH_SECTION="$(awk '/^## Watch list/{flag=1; next} /^## /{flag=0} flag' "$MAP" 2>/dev/null)"
  if [ -n "$WATCH_SECTION" ]; then
    while IFS= read -r line; do
      TERM="$(printf '%s' "$line" | sed -E 's/^[-* ]+//; s/[[:space:]]*$//')"
      [ -z "$TERM" ] && continue
      case "$TARGET" in
        *"$TERM"*)
          SURFACED="${SURFACED}watched-path "
          printf 'Maude: about to touch %s — that one is on the watch list. Make sure you know why.\n' "$TARGET" >&2
          break
          ;;
      esac
    done <<< "$WATCH_SECTION"
  fi
fi

# Check 2: cross-project patterns — has she seen this filename hit a known issue?
if [ -s "$USER_DIR/patterns.md" ]; then
  BASE="$(basename "$TARGET")"
  PATTERN_HIT="$(grep -m1 -i "$BASE" "$USER_DIR/patterns.md" 2>/dev/null | head -c 200)"
  if [ -n "$PATTERN_HIT" ]; then
    printf 'Maude: cross-project pattern on %s: %s\n' "$BASE" "$PATTERN_HIT" >&2
    SURFACED="${SURFACED}pattern "
  fi
fi

# Check 3: registry-file class — extra-careful on settings.json / installed_plugins.json
case "$TARGET" in
  */.claude/settings*.json|*/installed_plugins.json|*/known_marketplaces.json)
    printf 'Maude: %s is a Claude Code registry file. Read first; format must match exactly. Backup if you can.\n' "$TARGET" >&2
    SURFACED="${SURFACED}registry "
    ;;
esac

# Check 4: CLAUDE.md unread this session — Claude is about to edit without
# having read the project's hard rules. Once-per-day cooldown via care.json.
CARE="$(maude_self_dir)/care.json"
if command -v jq >/dev/null 2>&1; then
  TODAY="$(date +%Y-%m-%d)"
  WARNED_DATE=""
  [ -f "$CARE" ] && WARNED_DATE="$(jq -r '.claudemd_warned // ""' "$CARE" 2>/dev/null)"
  if [ "$WARNED_DATE" != "$TODAY" ]; then
    PROJ_DIR="$(maude_project_dir)"
    PROJ_CLAUDEMD="$PROJ_DIR/CLAUDE.md"
    USER_CLAUDEMD="$HOME/.claude/CLAUDE.md"
    NESTED_CLAUDEMD="$PROJ_DIR/.claude/CLAUDE.md"
    if [ -f "$PROJ_CLAUDEMD" ] || [ -f "$USER_CLAUDEMD" ] || [ -f "$NESTED_CLAUDEMD" ]; then
      TRACE="$(maude_trace_file)"
      READ_HIT=""
      if [ -f "$TRACE" ]; then
        READ_HIT="$(jq -r 'select(.tool == "Read" and (.target // "" | endswith("CLAUDE.md"))) | .target' "$TRACE" 2>/dev/null | head -1)"
      fi
      if [ -z "$READ_HIT" ]; then
        printf 'Maude: about to edit %s but CLAUDE.md has not been Read this session. Worth reading the rules first.\n' "$TARGET" >&2
        SURFACED="${SURFACED}claudemd-unread "
        if [ -f "$CARE" ]; then
          maude_care_set "$CARE" --arg t "$TODAY" '.claudemd_warned = $t'
        fi
      fi
    fi
  fi
fi

# Log to project-local trace if we surfaced anything
if [ -n "$SURFACED" ]; then
  maude_log_trace "pre-tool" "flags=${SURFACED% } target=$TARGET"
fi

exit 0
