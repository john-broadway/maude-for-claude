#!/usr/bin/env bash
# check-satellites.sh — verify the off-repo surfaces (the satellites in PUBLISHING.md §B)
# say what Maude is NOW. The durable answer to "did a leaf fall stale?"
#
# Usage:  scripts/check-satellites.sh <version>      e.g.  scripts/check-satellites.sh 0.37.0
# Needs:  gh (authenticated), base64, grep, jq.
# Exit:   0 if every satellite is current; 1 if any is stale or unfetchable.
#
# What "current" means changed on 2026-11-16. The satellites were rewritten in John's own
# words (2026-11) and carry NO version on purpose, so the old check (is "vX" present?) read
# every page as stale forever while the line that really went stale (the license, Apache to
# AGPL with 0.36.0) passed unseen. Each satellite is now checked for:
#   1. the exact license line in Maude's block, the license read from plugin.json;
#   2. on the Maude page, the command count in words, counted from commands/*.md;
#   3. no Maude version other than <version>: a page may name none, never an old one.
# The lines are exact on purpose: a sibling project's license on the same page must not
# satisfy Maude's. When John reshapes a page, the line here moves with it.

set +e
VER="${1:?usage: check-satellites.sh <version>   e.g. 0.37.0}"
VER="${VER#v}"   # accept 0.37.0 or v0.37.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

LICENSE="$(jq -r '.license // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
[ -n "$LICENSE" ] || { printf '  ??    plugin.json carries no license\n'; exit 1; }
NCMD="$(find "$ROOT/commands" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
WORDS=(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen
       fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three
       twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty)
CMDWORD="${WORDS[$NCMD]:-$NCMD}"
CMDWORD="$(printf '%s' "${CMDWORD:0:1}" | tr '[:lower:]' '[:upper:]')${CMDWORD:1}"

fetch() { gh api "repos/$1/contents/$2" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null; }

# check <repo> <path> <label> <fixed line that must be present>...
check() {
  local repo="$1" path="$2" body want old bad=0; shift 2
  body="$(fetch "$repo" "$path")"
  if [ -z "$body" ]; then
    printf '  ??    %s/%s — could not fetch\n' "$repo" "$path"; fail=1; return
  fi
  for want in "$@"; do
    # A want starting with "=" is a WHOLE line (leading blanks trimmed), so a sibling's
    # longer line ending in the same license cannot stand in for Maude's own.
    if [ "${want:0:1}" = "=" ]; then
      want="${want:1}"
      printf '%s\n' "$body" | sed 's/^[[:space:]]*//' | grep -qxF -- "$want" && continue
    elif printf '%s\n' "$body" | grep -qF -- "$want"; then
      continue
    fi
    printf '  STALE %s/%s — missing: %s\n' "$repo" "$path" "$want"; bad=1
  done
  # A Maude version on the page must be the current one. Only the Maude page and Maude's own
  # block name Maude versions; sibling projects' versions on the shared pages are theirs.
  if [ "$path" = "maude/index.html" ]; then
    old="$(printf '%s\n' "$body" | grep -oE 'v0\.[0-9]+\.[0-9]+' | grep -vxF "v$VER" | sort -u | tr '\n' ' ')"
    if [ -n "$old" ]; then
      printf '  STALE %s/%s — names an old version: %s\n' "$repo" "$path" "$old"; bad=1
    fi
  fi
  [ "$bad" = 0 ] && printf '  ok    %s/%s\n' "$repo" "$path"
  [ "$bad" = 0 ] || fail=1
}

printf 'Checking Maude satellites (license %s, %s commands, v%s) ...\n' "$LICENSE" "$NCMD" "$VER"
check john-broadway/john-broadway              README.md \
  "$(printf '=%s.' "$LICENSE")"
check john-broadway/john-broadway.github.io    index.html \
  "$(printf '=<p class="status">%s.</p>' "$LICENSE")"
check john-broadway/john-broadway.github.io    maude/index.html \
  "$(printf 'Claude Code &middot; %s' "$LICENSE")" \
  "$(printf '%s commands in all' "$CMDWORD")"

if [ "$fail" = 0 ]; then
  printf 'All satellites are current.\n'
else
  printf 'Some satellites STALE — sweep them (PUBLISHING.md §B), then re-run.\n'
fi
exit "$fail"
