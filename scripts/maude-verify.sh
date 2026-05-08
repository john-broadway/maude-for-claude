#!/usr/bin/env bash
# Maude verify — programmatic audit of project state. The audit Maude runs
# before saying "ready." Catches version drift, JSON breakage, broken links,
# stale header dates, missing CHANGELOG entries, and watch-list-path drift.
#
# Output: structured report. Counts by category. Last line: "N findings".
# Exit code: 0 if no findings, 1 if any findings. Caller (e.g., /maude:conscience)
# decides what to do with the findings.
#
# Usage: maude-verify.sh [project_dir]
#   project_dir defaults to $CLAUDE_PROJECT_DIR or pwd.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
# Source common helpers if present (hooks/scripts/_maude-common.sh)
COMMON="$DIR/../hooks/scripts/_maude-common.sh"
[ -f "$COMMON" ] && . "$COMMON"

PROJ="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$PROJ" || { echo "verify: cannot cd to $PROJ" >&2; exit 1; }

FINDINGS=0
emit() { printf '  %s\n' "$1"; FINDINGS=$((FINDINGS + 1)); }

printf 'Maude verify: %s\n' "$PROJ"
printf '%s\n' "----------------------------------------"

# ─── Check 1: JSON validity ──────────────────────────────────────────
printf '\n## JSON validity\n'
if command -v jq >/dev/null 2>&1; then
  JSON_FILES=$(find . -name "*.json" -not -path "./.git/*" -not -path "./.maude/*" -not -path "./.pytest_cache/*" -not -path "./node_modules/*" 2>/dev/null)
  COUNT=0
  for f in $JSON_FILES; do
    COUNT=$((COUNT + 1))
    jq . "$f" > /dev/null 2>&1 || emit "BROKEN: $f"
  done
  printf '  %d JSON files scanned\n' "$COUNT"
else
  printf '  jq not available — skipped\n'
fi

# ─── Check 2: Version consistency ────────────────────────────────────
printf '\n## Version consistency\n'
CANONICAL=""
if [ -f .claude-plugin/plugin.json ] && command -v jq >/dev/null 2>&1; then
  CANONICAL=$(jq -r '.version // ""' .claude-plugin/plugin.json 2>/dev/null)
  printf '  Canonical (plugin.json): %s\n' "$CANONICAL"

  # Check marketplace.json matches
  if [ -f .claude-plugin/marketplace.json ]; then
    M_VER=$(jq -r '.plugins[0].version // ""' .claude-plugin/marketplace.json 2>/dev/null)
    if [ "$M_VER" != "$CANONICAL" ]; then
      emit "MISMATCH: marketplace.json plugins[0].version = '$M_VER' (expected '$CANONICAL')"
    fi
  fi

  # Find any version-string mentions in markdown/json/sh and group
  if [ -n "$CANONICAL" ]; then
    # Pull all v0.X.Y references
    ALL_REFS=$(grep -rEho "v[0-9]+\.[0-9]+\.[0-9]+" . \
      --include="*.md" --include="*.json" --include="*.sh" \
      --exclude-dir=.git --exclude-dir=.pytest_cache --exclude-dir=.maude \
      2>/dev/null | sort -u)
    if [ -n "$ALL_REFS" ]; then
      printf '  Distinct version refs found in repo: %s\n' "$(printf '%s' "$ALL_REFS" | tr '\n' ' ')"
    fi

    # CHANGELOG should have an entry for the canonical version
    if [ -f CHANGELOG.md ]; then
      if ! grep -qE "^## v$CANONICAL\b" CHANGELOG.md; then
        emit "CHANGELOG.md is missing a v$CANONICAL section header"
      fi
    fi
  fi
fi

# ─── Check 3: README "What's new" mentions canonical version ─────────
printf "\n## README 'What's new' freshness\n"
if [ -f README.md ] && [ -n "$CANONICAL" ]; then
  if grep -q '^## What.s new' README.md; then
    # Look for canonical version in the What's new section
    if ! awk '/^## What.s new/{flag=1; next} /^## /{flag=0} flag' README.md | grep -q "v$CANONICAL"; then
      emit "README 'What's new' section does not mention v$CANONICAL"
    else
      printf "  v%s present in 'What's new'\n" "$CANONICAL"
    fi
  else
    printf "  No 'What's new' section in README — skipped\n"
  fi
fi

# ─── Check 4: Header Revised dates within 14 days ────────────────────
printf '\n## Header revised dates\n'
TODAY_EPOCH=$(date +%s)
STALE_LIMIT_DAYS=14
HDRS=$(grep -rln "Revised:" . --include="*.md" --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache 2>/dev/null)
if [ -n "$HDRS" ]; then
  while IFS= read -r f; do
    # Extract date in YYYY-MM-DD form from the first Revised: line
    REVDATE=$(grep -m1 -oE 'Revised:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [ -n "$REVDATE" ]; then
      REV_EPOCH=$(date -d "$REVDATE" +%s 2>/dev/null)
      if [ -n "$REV_EPOCH" ]; then
        DAYS=$(( (TODAY_EPOCH - REV_EPOCH) / 86400 ))
        if [ "$DAYS" -gt "$STALE_LIMIT_DAYS" ]; then
          emit "$f Revised: $REVDATE (${DAYS} days ago — stale)"
        fi
      fi
    fi
  done <<< "$HDRS"
fi
[ "$FINDINGS" -eq 0 ] || true  # keep going

# ─── Check 5: Relative markdown links resolve ────────────────────────
printf '\n## Markdown link integrity\n'
if [ -f README.md ]; then
  BROKEN=0
  while IFS= read -r link; do
    case "$link" in
      http*) ;;
      \#*) ;;
      "") ;;
      *)
        # Strip fragment
        LINK_NO_FRAG="${link%%#*}"
        [ -z "$LINK_NO_FRAG" ] && continue
        if [ ! -e "$LINK_NO_FRAG" ]; then
          emit "README broken link: $link"
          BROKEN=$((BROKEN+1))
        fi
        ;;
    esac
  done < <(grep -oE '\]\([^)]+\)' README.md | sed 's/^](//;s/)$//')
  [ "$BROKEN" -eq 0 ] && printf '  README relative links all resolve\n'
fi

# ─── Check 6: House-map watch-list paths exist ───────────────────────
printf '\n## Watch-list path reconciliation\n'
MAP=".maude/plugin/house-map.md"
if [ -f "$MAP" ]; then
  WATCH=$(awk '/^## Watch list/{flag=1; next} /^## /{flag=0} flag' "$MAP" 2>/dev/null)
  if [ -n "$WATCH" ]; then
    MISSING=0
    while IFS= read -r line; do
      TERM=$(printf '%s' "$line" | sed -E 's/^[-* ]+//; s/[[:space:]]*$//; s/^[`]//; s/[`]$//')
      [ -z "$TERM" ] && continue
      # Try as relative path; if not found, skip silently (terms can be tags too)
      case "$TERM" in
        /*|./*|[a-zA-Z0-9._-]*/*)
          if [ ! -e "$TERM" ]; then
            emit "Watch-list path missing: $TERM"
            MISSING=$((MISSING+1))
          fi
          ;;
      esac
    done <<< "$WATCH"
    [ "$MISSING" -eq 0 ] && printf '  Watch-list paths all resolve\n'
  else
    printf '  No watch-list section in house-map\n'
  fi
else
  printf '  No house-map yet (run /maude:found) — skipped\n'
fi

# ─── Check 7: Worn-framings (project-configurable) ───────────────────
printf '\n## Worn-framing scan\n'
WORN_FILE=".maude/plugin/worn-framings.txt"
if [ -f "$WORN_FILE" ]; then
  WORN_HITS=0
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    case "$phrase" in '#'*) continue;; esac
    HITS=$(grep -rln "$phrase" . --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache 2>/dev/null | grep -v "^./$WORN_FILE\$" | grep -v "^./CHANGELOG.md\$")
    if [ -n "$HITS" ]; then
      while IFS= read -r f; do
        emit "Worn framing in $f: '$phrase'"
        WORN_HITS=$((WORN_HITS+1))
      done <<< "$HITS"
    fi
  done < "$WORN_FILE"
  [ "$WORN_HITS" -eq 0 ] && printf '  No worn-framing hits (against %s)\n' "$WORN_FILE"
else
  printf '  No %s — skipped (create one to scan project-specific phrases)\n' "$WORN_FILE"
fi

# ─── Summary ─────────────────────────────────────────────────────────
printf '\n%s\n' "----------------------------------------"
printf '%d findings\n' "$FINDINGS"
[ "$FINDINGS" -eq 0 ] && exit 0 || exit 1
